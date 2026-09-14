//! Side-effect-free `gitframe review-input` process adapter.

const std = @import("std");
const codec = @import("codec.zig");
const instructions = @import("instructions.zig");
const limits = @import("limits.zig");
const patch_plan = @import("patch_plan.zig");
const projection_frame = @import("projection_frame.zig");
const protocol = @import("protocol.zig");
const committed_codec = @import("../committed_review/codec.zig");
const identity = @import("../committed_review/identity.zig");
const target_mod = @import("../committed_review/target.zig");
const git_command = @import("../git/command.zig");
const root_capability = @import("../repo/root_capability.zig");

pub const max_request_bytes: usize = limits.max_input_header_bytes + limits.max_projection_frame_bytes;

pub const CommandOutput = struct {
    exit_code: u8,
    bytes: []u8,

    pub fn deinit(self: *CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Owned, provider-neutral deterministic input for one model call. All slices
/// in `summary` and `units` are backed by `arena` and remain valid until
/// `deinit`.
pub const PlannedInput = struct {
    arena: std.heap.ArenaAllocator,
    summary: protocol.ReviewPlanSummary,
    units: []const protocol.ReviewUnit,

    pub fn deinit(self: *PlannedInput) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const PlanError = std.mem.Allocator.Error || error{
    ReviewUnitTooLarge,
    ReviewLineTooLarge,
    LimitExceeded,
    UnsupportedProjection,
    InvalidProjection,
    UnsupportedGuidance,
    GuidanceReadFailed,
    InvalidPlan,
};

const Failure = struct {
    exit_code: u8,
    code: []const u8,
    message: []const u8,
    limit: ?limits.Violation = null,
};

const Chunk = struct {
    file_index: usize,
    hunk_start: usize,
    hunk_end: usize,
    coverage: protocol.CoverageSpan,
};

/// Admit and materialize one complete request. No target resolution, Store,
/// recovery, TUI, config or working-tree/index content read occurs.
pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*const std.process.Environ.Map,
    arguments: []const []const u8,
    request_bytes: []const u8,
) std.mem.Allocator.Error!CommandOutput {
    if (arguments.len != 0) return errorOutput(allocator, .{
        .exit_code = 2,
        .code = "invalid_arguments",
        .message = "review-input accepts no arguments",
    });
    if (request_bytes.len == 0) return errorOutput(allocator, .{
        .exit_code = 2,
        .code = "invalid_review_input_frame",
        .message = "review-input requires one exact bounded input frame",
    });
    if (request_bytes.len > max_request_bytes) return errorOutput(allocator, limitFailure(.{
        .resource = "review_input_frame_bytes",
        .observed = request_bytes.len,
        .allowed = max_request_bytes,
    }));

    var frame_limit: ?limits.Violation = null;
    var frame = projection_frame.parseWithLimit(allocator, request_bytes, &frame_limit) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedSchemaVersion => errorOutput(allocator, .{
            .exit_code = 2,
            .code = "unsupported_schema_version",
            .message = "review-input schema version is not supported",
        }),
        error.InvalidTarget => errorOutput(allocator, .{
            .exit_code = 2,
            .code = "invalid_target",
            .message = "review-input target is invalid",
        }),
        error.LimitExceeded => errorOutput(allocator, limitFailure(frame_limit.?)),
        error.InvalidFrame => errorOutput(allocator, .{
            .exit_code = 2,
            .code = "invalid_review_input_frame",
            .message = "review-input frame is malformed or incomplete",
        }),
    };
    defer frame.deinit();

    // Preserve the command adapter's established validation order: malformed
    // projection bytes are rejected before the repository path is consulted.
    // The hosted path calls `planAlloc` directly and parses only once.
    {
        var validation_arena = std.heap.ArenaAllocator.init(allocator);
        defer validation_arena.deinit();
        var validation_limit: ?limits.Violation = null;
        _ = patch_plan.parseWithLimit(validation_arena.allocator(), frame.target.object_format, frame.patch_bytes, &validation_limit) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ReviewLineTooLarge => errorOutput(allocator, lineTooLargeFailure(validation_limit.?)),
            error.LimitExceeded => errorOutput(allocator, limitFailure(validation_limit.?)),
            error.UnsupportedBinary, error.UnsupportedFileType, error.UnsupportedContent, error.MetadataOnly, error.UnsupportedCombinedDiff => errorOutput(allocator, .{
                .exit_code = 5,
                .code = "unsupported_projection",
                .message = "projection contains a file or content form unsupported by AI review v1",
            }),
            error.InvalidPatch, error.InvalidPath => errorOutput(allocator, .{
                .exit_code = 2,
                .code = "invalid_projection",
                .message = "projection is not one complete canonical Git patch",
            }),
        };
    }

    var root = root_capability.RootCapability.openCanonical(frame.repository_path) catch
        return errorOutput(allocator, .{
            .exit_code = 3,
            .code = "invalid_repository",
            .message = "review-input repository path is unavailable or not canonical",
        });
    defer root.deinit();
    var environment = git_command.LocalGitEnvironment.initFromParent(allocator, environment_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorOutput(allocator, internalFailure()),
    };
    defer environment.deinit();
    var violation: ?limits.Violation = null;
    var planned = planAlloc(allocator, io, .{
        .cwd = root.dir(),
        .environment = &environment,
    }, frame.target, frame.patch_bytes, &violation) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReviewUnitTooLarge => errorOutput(allocator, unitTooLargeFailure(violation.?)),
        error.ReviewLineTooLarge => errorOutput(allocator, lineTooLargeFailure(violation.?)),
        error.LimitExceeded => errorOutput(allocator, limitFailure(violation.?)),
        error.UnsupportedProjection => errorOutput(allocator, .{
            .exit_code = 5,
            .code = "unsupported_projection",
            .message = "projection contains a file or content form unsupported by AI review v1",
        }),
        error.InvalidProjection => errorOutput(allocator, .{
            .exit_code = 2,
            .code = "invalid_projection",
            .message = "projection is not one complete canonical Git patch",
        }),
        error.UnsupportedGuidance => errorOutput(allocator, .{
            .exit_code = 5,
            .code = "unsupported_guidance",
            .message = "exact-head repository guidance is invalid or unsupported",
        }),
        error.GuidanceReadFailed => errorOutput(allocator, .{
            .exit_code = 6,
            .code = "guidance_read_failed",
            .message = "exact-head repository guidance could not be read",
        }),
        error.InvalidPlan => errorOutput(allocator, internalFailure()),
    };
    defer planned.deinit();
    return successOutputFromPlan(allocator, &planned, &violation) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReviewUnitTooLarge => errorOutput(allocator, unitTooLargeFailure(violation.?)),
        error.LimitExceeded => errorOutput(allocator, limitFailure(violation.?)),
        error.InvalidPlan => errorOutput(allocator, internalFailure()),
    };
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*const std.process.Environ.Map,
    arguments: []const []const u8,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
) !u8 {
    if (arguments.len != 0) {
        var output = try executeAlloc(allocator, io, environment_map, arguments, &.{});
        defer output.deinit(allocator);
        try writeAll(stdout_file, io, output.bytes);
        return output.exit_code;
    }
    var read_buffer: [4096]u8 = undefined;
    var reader_stream = stdin_file.readerStreaming(io, &read_buffer);
    const request = reader_stream.interface.allocRemaining(allocator, .limited(max_request_bytes + 1)) catch |err| switch (err) {
        error.OutOfMemory => return writeEmergency(stdout_file, io),
        else => {
            var output = try errorOutput(allocator, .{
                .exit_code = 4,
                .code = "review_input_limit_exceeded",
                .message = "review-input exceeded a finite v1 resource limit",
                .limit = .{ .resource = "review_input_frame_bytes", .observed = max_request_bytes + 1, .allowed = max_request_bytes },
            });
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

const BuildError = std.mem.Allocator.Error || error{ LimitExceeded, ReviewUnitTooLarge, InvalidPlan };

const PlanValue = struct {
    summary: protocol.ReviewPlanSummary,
    units: []const protocol.ReviewUnit,
};

/// Materialize the same deterministic plan used by `review-input`, but from a
/// caller-retained physical repository context rather than a path-bearing
/// command frame.
pub fn planAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: target_mod.CommittedReviewTarget,
    patch_bytes: []const u8,
    violation: *?limits.Violation,
) PlanError!PlannedInput {
    violation.* = null;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const owned_patch = try arena.dupe(u8, patch_bytes);
    const parsed_patch = patch_plan.parseWithLimit(arena, target.object_format, owned_patch, violation) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReviewLineTooLarge => error.ReviewLineTooLarge,
        error.LimitExceeded => error.LimitExceeded,
        error.UnsupportedBinary, error.UnsupportedFileType, error.UnsupportedContent, error.MetadataOnly, error.UnsupportedCombinedDiff => error.UnsupportedProjection,
        error.InvalidPatch, error.InvalidPath => error.InvalidProjection,
    };
    const guidance = instructions.materializeWithLimit(arena, io, context, target, parsed_patch.files, violation) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LimitExceeded => error.LimitExceeded,
        error.InvalidPath, error.ConflictingGuidance, error.UnsupportedGuidance => error.UnsupportedGuidance,
        error.GuidanceReadFailed => error.GuidanceReadFailed,
    };
    const value = try buildPlanValue(arena, target, owned_patch, parsed_patch, guidance, violation);
    return .{ .arena = arena_state, .summary = value.summary, .units = value.units };
}

fn buildPlanValue(
    arena: std.mem.Allocator,
    target: target_mod.CommittedReviewTarget,
    patch_bytes: []const u8,
    parsed_patch: patch_plan.Plan,
    guidance: instructions.Materialized,
    violation: *?limits.Violation,
) BuildError!PlanValue {
    if (guidance.chains.len != parsed_patch.files.len) return error.InvalidPlan;
    const chunks = try planChunks(arena, parsed_patch, violation);
    if (chunks.len > limits.max_review_units) {
        limits.record(violation, "review_units", chunks.len, limits.max_review_units);
        return error.LimitExceeded;
    }
    const unit_count: u16 = @intCast(chunks.len);
    const zero_digest: identity.Sha256Digest = .{ .bytes = [_]u8{0} ** 32 };
    const units = try arena.alloc(protocol.ReviewUnit, chunks.len);
    for (chunks, 0..) |chunk, index| {
        units[index] = try buildUnit(arena, parsed_patch.files[chunk.file_index], guidance.chains[chunk.file_index], chunk, @intCast(index + 1), unit_count, zero_digest, violation);
    }
    const projection_digest = identity.Sha256Digest.hash(patch_bytes);
    var summary: protocol.ReviewPlanSummary = .{
        .schema_version = limits.schema_version,
        .target = target,
        .projection_digest = projection_digest,
        .instruction_set_digest = guidance.instruction_set_digest,
        .unit_count = unit_count,
        .plan_digest = zero_digest,
        .limits = .v1,
    };
    const plan_digest = try computePlanDigest(arena, &summary, units, violation);
    summary.plan_digest = plan_digest;
    for (units) |*unit| unit.plan_digest = plan_digest;

    return .{ .summary = summary, .units = units };
}

fn successOutputFromPlan(
    output_allocator: std.mem.Allocator,
    planned: *PlannedInput,
    violation: *?limits.Violation,
) BuildError!CommandOutput {
    return successOutputFromValues(output_allocator, planned.arena.allocator(), planned.summary, planned.units, violation);
}

fn successOutputFromValues(
    output_allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    summary: protocol.ReviewPlanSummary,
    units: []const protocol.ReviewUnit,
    violation: *?limits.Violation,
) BuildError!CommandOutput {
    const summary_bytes = codec.writePlanSummaryAlloc(scratch, &summary) catch |err| return mapCodecBuildError(err, violation, "plan_summary_bytes", limits.max_plan_summary_bytes);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(output_allocator);
    try appendBounded(output_allocator, &output, "{\"schema_version\":1,\"status\":\"ok\",\"summary\":", violation);
    try appendBounded(output_allocator, &output, withoutFinalLf(summary_bytes) orelse return error.InvalidPlan, violation);
    try appendBounded(output_allocator, &output, ",\"units\":[", violation);
    for (units, 0..) |*unit, index| {
        const unit_bytes = codec.writeReviewUnitAlloc(scratch, unit) catch |err| return mapCodecBuildError(err, violation, "unit_bytes", limits.max_unit_bytes);
        if (unit_bytes.len > limits.max_unit_bytes) {
            limits.record(violation, "unit_bytes", unit_bytes.len, limits.max_unit_bytes);
            return error.ReviewUnitTooLarge;
        }
        if (index > 0) try appendBounded(output_allocator, &output, ",", violation);
        try appendBounded(output_allocator, &output, withoutFinalLf(unit_bytes) orelse return error.InvalidPlan, violation);
    }
    try appendBounded(output_allocator, &output, "]}\n", violation);
    return .{ .exit_code = 0, .bytes = try output.toOwnedSlice(output_allocator) };
}

// Direct construction seam retained for the existing deterministic domain
// tests. Production callers use `planAlloc` so all borrowed patch bytes are
// copied into the returned owner.
fn buildSuccess(
    output_allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    target: target_mod.CommittedReviewTarget,
    patch_bytes: []const u8,
    parsed_patch: patch_plan.Plan,
    guidance: instructions.Materialized,
    violation: *?limits.Violation,
) BuildError!CommandOutput {
    const value = try buildPlanValue(arena, target, patch_bytes, parsed_patch, guidance, violation);
    return successOutputFromValues(output_allocator, arena, value.summary, value.units, violation);
}

fn planChunks(allocator: std.mem.Allocator, plan: patch_plan.Plan, violation: *?limits.Violation) BuildError![]const Chunk {
    var chunks: std.ArrayList(Chunk) = .empty;
    var coverage_cursor: u32 = 0;
    for (plan.files, 0..) |file, file_index| {
        var hunk_start: usize = 0;
        while (hunk_start < file.hunks.len) {
            const start = if (hunk_start == 0) file.metadata_coverage.start else file.hunks[hunk_start].coverage.start;
            var hunk_end = hunk_start;
            var old_location_count: usize = 0;
            var new_location_count: usize = 0;
            var line_count: usize = 0;
            while (hunk_end < file.hunks.len) {
                const hunk = file.hunks[hunk_end];
                const raw_size = hunk.coverage.end_exclusive - start;
                const candidate_old = std.math.add(usize, old_location_count, hunk.old_count) catch return error.InvalidPlan;
                const candidate_new = std.math.add(usize, new_location_count, hunk.new_count) catch return error.InvalidPlan;
                const candidate_lines = std.math.add(usize, line_count, hunk.lines.len) catch return error.InvalidPlan;
                const fits_hard_limits = candidate_old <= limits.max_locations_per_side and
                    candidate_new <= limits.max_locations_per_side and
                    candidate_lines <= limits.max_lines_per_unit;
                if (!fits_hard_limits) {
                    if (hunk_end == hunk_start) {
                        if (candidate_old > limits.max_locations_per_side) limits.record(violation, "locations_per_side", candidate_old, limits.max_locations_per_side) else if (candidate_new > limits.max_locations_per_side) limits.record(violation, "locations_per_side", candidate_new, limits.max_locations_per_side) else limits.record(violation, "lines_per_unit", candidate_lines, limits.max_lines_per_unit);
                        return error.ReviewUnitTooLarge;
                    }
                    break;
                }
                if (raw_size > limits.unit_raw_fragment_target_bytes and hunk_end != hunk_start) break;
                old_location_count = candidate_old;
                new_location_count = candidate_new;
                line_count = candidate_lines;
                hunk_end += 1;
            }
            if (chunks.items.len == limits.max_review_units) {
                limits.record(violation, "review_units", chunks.items.len + 1, limits.max_review_units);
                return error.LimitExceeded;
            }
            const end = file.hunks[hunk_end - 1].coverage.end_exclusive;
            if (start != coverage_cursor or end <= start) return error.InvalidPlan;
            try chunks.append(allocator, .{
                .file_index = file_index,
                .hunk_start = hunk_start,
                .hunk_end = hunk_end,
                .coverage = .{ .start = start, .end_exclusive = end },
            });
            coverage_cursor = end;
            hunk_start = hunk_end;
        }
    }
    if (coverage_cursor != plan.patch_size) return error.InvalidPlan;
    return chunks.toOwnedSlice(allocator);
}

fn buildUnit(
    allocator: std.mem.Allocator,
    file: patch_plan.File,
    guidance: instructions.FileChains,
    chunk: Chunk,
    ordinal: u16,
    unit_count: u16,
    plan_digest: identity.Sha256Digest,
    violation: *?limits.Violation,
) BuildError!protocol.ReviewUnit {
    const source_hunks = file.hunks[chunk.hunk_start..chunk.hunk_end];
    var guidance_bytes: usize = 0;
    for ([_][]const protocol.Guidance{ guidance.before, guidance.after }) |chain| {
        for (chain) |item| {
            guidance_bytes = std.math.add(usize, guidance_bytes, item.content.len) catch {
                limits.record(violation, "guidance_per_unit_bytes", limits.max_guidance_per_unit_bytes + 1, limits.max_guidance_per_unit_bytes);
                return error.LimitExceeded;
            };
        }
    }
    if (guidance_bytes > limits.max_guidance_per_unit_bytes) {
        limits.record(violation, "guidance_per_unit_bytes", guidance_bytes, limits.max_guidance_per_unit_bytes);
        return error.LimitExceeded;
    }
    var before_total: usize = 0;
    var after_total: usize = 0;
    for (source_hunks) |hunk| {
        before_total = std.math.add(usize, before_total, hunk.old_count) catch return error.InvalidPlan;
        after_total = std.math.add(usize, after_total, hunk.new_count) catch return error.InvalidPlan;
    }
    if (before_total > limits.max_locations_per_side or after_total > limits.max_locations_per_side) {
        limits.record(violation, "locations_per_side", @max(before_total, after_total), limits.max_locations_per_side);
        return error.ReviewUnitTooLarge;
    }
    const hunks = try allocator.alloc(protocol.ReviewHunk, source_hunks.len);
    var before_ordinal: u16 = 1;
    var after_ordinal: u16 = 1;
    for (source_hunks, 0..) |source_hunk, hunk_index| {
        const lines = try allocator.alloc(protocol.DiffLine, source_hunk.lines.len);
        var old_consumed: u32 = 0;
        var new_consumed: u32 = 0;
        for (source_hunk.lines, 0..) |source_line, line_index| {
            var before_id: ?protocol.LocationId = null;
            var after_id: ?protocol.LocationId = null;
            if (source_line.kind != .added) {
                const id: protocol.LocationId = .{ .side = .before, .ordinal = before_ordinal };
                before_id = id;
                before_ordinal = std.math.add(u16, before_ordinal, 1) catch return error.InvalidPlan;
                old_consumed = std.math.add(u32, old_consumed, 1) catch return error.InvalidPlan;
            }
            if (source_line.kind != .removed) {
                const id: protocol.LocationId = .{ .side = .after, .ordinal = after_ordinal };
                after_id = id;
                after_ordinal = std.math.add(u16, after_ordinal, 1) catch return error.InvalidPlan;
                new_consumed = std.math.add(u32, new_consumed, 1) catch return error.InvalidPlan;
            }
            lines[line_index] = .{
                .kind = source_line.kind,
                .text = source_line.text,
                .line_ending = source_line.line_ending,
                .before_location = before_id,
                .after_location = after_id,
            };
        }
        hunks[hunk_index] = .{
            .old_start = source_hunk.old_start,
            .old_count = source_hunk.old_count,
            .new_start = source_hunk.new_start,
            .new_count = source_hunk.new_count,
            .section = source_hunk.section,
            .lines = lines,
        };
        if (old_consumed != source_hunk.old_count or new_consumed != source_hunk.new_count) return error.InvalidPlan;
    }
    const spans = try allocator.alloc(protocol.CoverageSpan, 1);
    spans[0] = chunk.coverage;
    return .{
        .schema_version = limits.schema_version,
        .plan_digest = plan_digest,
        .unit_id = .{ .ordinal = ordinal },
        .ordinal = ordinal,
        .unit_count = unit_count,
        .old_path_bytes = file.old_path,
        .new_path_bytes = file.new_path,
        .display_path = file.display_path,
        .file_status = file.status,
        .metadata_lines = file.metadata_lines,
        .hunks = hunks,
        .before_guidance = guidance.before,
        .after_guidance = guidance.after,
        .coverage_spans = spans,
    };
}

fn computePlanDigest(
    allocator: std.mem.Allocator,
    summary: *const protocol.ReviewPlanSummary,
    units: []const protocol.ReviewUnit,
    violation: *?limits.Violation,
) BuildError!identity.Sha256Digest {
    var preimage: std.ArrayList(u8) = .empty;
    try preimage.appendSlice(allocator, "gitframe-ai-review-plan-v1\x00");
    const summary_bytes = codec.writePlanSummaryAlloc(allocator, summary) catch |err| return mapCodecBuildError(err, violation, "plan_summary_bytes", limits.max_plan_summary_bytes);
    try preimage.appendSlice(allocator, summary_bytes);
    for (units) |*unit| {
        const bytes = codec.writeReviewUnitAlloc(allocator, unit) catch |err| return mapCodecBuildError(err, violation, "unit_bytes", limits.max_unit_bytes);
        try preimage.appendSlice(allocator, bytes);
    }
    return identity.Sha256Digest.hash(preimage.items);
}

fn mapCodecBuildError(err: codec.ParseError, violation: *?limits.Violation, resource: []const u8, allowed: usize) BuildError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LimitExceeded, error.ArtifactTooLarge => limit: {
            limits.record(violation, resource, allowed + 1, allowed);
            break :limit error.LimitExceeded;
        },
        else => error.InvalidPlan,
    };
}

fn appendBounded(allocator: std.mem.Allocator, output: *std.ArrayList(u8), bytes: []const u8, violation: *?limits.Violation) BuildError!void {
    const total = std.math.add(usize, output.items.len, bytes.len) catch {
        limits.record(violation, "input_output_bytes", limits.max_review_input_output_bytes + 1, limits.max_review_input_output_bytes);
        return error.LimitExceeded;
    };
    if (total > limits.max_review_input_output_bytes) {
        limits.record(violation, "input_output_bytes", total, limits.max_review_input_output_bytes);
        return error.LimitExceeded;
    }
    try output.appendSlice(allocator, bytes);
}

fn withoutFinalLf(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n' or
        std.mem.indexOfScalar(u8, bytes[0 .. bytes.len - 1], '\n') != null) return null;
    return bytes[0 .. bytes.len - 1];
}

fn errorOutput(allocator: std.mem.Allocator, failure: Failure) std.mem.Allocator.Error!CommandOutput {
    if (failure.limit) |limit| {
        const bytes = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"status\":\"error\",\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\",\"resource\":\"{s}\",\"observed\":{d},\"allowed\":{d}}}}}\n", .{ failure.code, failure.message, limit.resource, limit.observed, limit.allowed });
        return .{ .exit_code = failure.exit_code, .bytes = bytes };
    }
    const bytes = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"status\":\"error\",\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}\n", .{ failure.code, failure.message });
    return .{ .exit_code = failure.exit_code, .bytes = bytes };
}

fn limitFailure(limit: limits.Violation) Failure {
    return .{ .exit_code = 4, .code = "review_input_limit_exceeded", .message = "review-input exceeded a finite v1 resource limit", .limit = limit };
}

fn unitTooLargeFailure(limit: limits.Violation) Failure {
    return .{ .exit_code = 4, .code = "review_unit_too_large", .message = "one whole-hunk review unit exceeds a finite v1 limit", .limit = limit };
}

fn lineTooLargeFailure(limit: limits.Violation) Failure {
    return .{ .exit_code = 4, .code = "review_line_too_large", .message = "one diff content line exceeds the 16 KiB limit", .limit = limit };
}

fn internalFailure() Failure {
    return .{ .exit_code = 70, .code = "internal_error", .message = "review-input could not complete" };
}

fn writeAll(file: std.Io.File, io: std.Io, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn writeEmergency(file: std.Io.File, io: std.Io) !u8 {
    const bytes = "{\"schema_version\":1,\"status\":\"error\",\"error\":{\"code\":\"internal_error\",\"message\":\"review-input could not complete\"}}\n";
    try writeAll(file, io, bytes);
    return 70;
}

fn testTarget() target_mod.CommittedReviewTarget {
    const oid = target_mod.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567") catch unreachable;
    return .{ .object_format = .sha1, .source_kind = .branch_range, .base_oid = oid, .head_oid = oid, .diff_base_oid = oid };
}

fn testTargetJson(allocator: std.mem.Allocator, target: *const target_mod.CommittedReviewTarget) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    try committed_codec.writeTarget(&stringify, target);
    return output.toOwnedSlice();
}

fn reviewInputRequestAlloc(
    allocator: std.mem.Allocator,
    repository: []const u8,
    target: *const target_mod.CommittedReviewTarget,
    patch: []const u8,
) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(repository.len));
    defer allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, repository);
    const target_json = try testTargetJson(allocator, target);
    defer allocator.free(target_json);
    const inner = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":{d}}}\n{s}", .{ target_json, patch.len, patch });
    defer allocator.free(inner);
    return std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"{s}\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ encoded, target_json, inner.len, inner });
}

fn expectLimitTerminal(output: CommandOutput, code: []const u8, message: []const u8, resource: []const u8, observed: usize, allowed: usize) !void {
    try std.testing.expectEqual(@as(u8, 4), output.exit_code);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"error\",\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\",\"resource\":\"{s}\",\"observed\":{d},\"allowed\":{d}}}}}\n", .{ code, message, resource, observed, allowed });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, output.bytes);
}

fn testPatchWithRawHunkSize(allocator: std.mem.Allocator, hunk_size: usize) ![]u8 {
    const metadata = "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n";
    const header = "@@ -1,4 +1,4 @@\n";
    const framing_bytes = header.len + 8 * 2;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(metadata);
    try output.writer.writeAll(header);
    var remaining = hunk_size - framing_bytes;
    const filler = try allocator.alloc(u8, (remaining + 7) / 8);
    defer allocator.free(filler);
    @memset(filler, 'x');
    for (0..8) |index| {
        const count = (remaining + (8 - index) - 1) / (8 - index);
        try output.writer.writeByte(if (index % 2 == 0) '-' else '+');
        try output.writer.writeAll(filler[0..count]);
        try output.writer.writeByte('\n');
        remaining -= count;
    }
    return output.toOwnedSlice();
}

fn testBuildLargeCanonicalOutput(
    output_allocator: std.mem.Allocator,
    newline_count: usize,
    first_metadata_extra: usize,
    violation: *?limits.Violation,
) BuildError!CommandOutput {
    var arena_owner = std.heap.ArenaAllocator.init(output_allocator);
    defer arena_owner.deinit();
    const arena = arena_owner.allocator();
    const guidance_content = try arena.alloc(u8, limits.max_guidance_per_unit_bytes / 2);
    @memset(guidance_content, 'g');
    if (newline_count > guidance_content.len) return error.InvalidPlan;
    @memset(guidance_content[0..newline_count], '\n');
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const guidance_items = try arena.alloc(protocol.Guidance, 1);
    guidance_items[0] = .{
        .head_oid = oid,
        .path_bytes = "AGENTS.md",
        .blob_oid = oid,
        .content_digest = identity.Sha256Digest.hash(guidance_content),
        .content = guidance_content,
    };
    const first_metadata_text = try arena.alloc(u8, "diff --git a/a b/a".len + first_metadata_extra);
    @memcpy(first_metadata_text[0.."diff --git a/a b/a".len], "diff --git a/a b/a");
    @memset(first_metadata_text["diff --git a/a b/a".len..], 'x');
    const first_metadata = try arena.alloc([]const u8, 1);
    first_metadata[0] = first_metadata_text;
    const common_metadata = try arena.alloc([]const u8, 1);
    common_metadata[0] = "diff --git a/a b/a";
    const content_lines = try arena.alloc(patch_plan.Line, 1);
    content_lines[0] = .{ .kind = .context, .text = "x", .line_ending = .lf };
    const files = try arena.alloc(patch_plan.File, limits.max_review_units);
    const hunks = try arena.alloc(patch_plan.Hunk, limits.max_review_units);
    const chains = try arena.alloc(instructions.FileChains, limits.max_review_units);
    for (files, hunks, chains, 0..) |*file, *hunk, *chain, index| {
        const start: u32 = @intCast(index * 2);
        hunk.* = .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .section = null, .lines = content_lines, .coverage = .{ .start = start + 1, .end_exclusive = start + 2 } };
        file.* = .{
            .old_path = "a",
            .new_path = "a",
            .display_path = "a",
            .status = .modified,
            .metadata_lines = if (index == 0) first_metadata else common_metadata,
            .metadata_coverage = .{ .start = start, .end_exclusive = start + 1 },
            .hunks = hunks[index .. index + 1],
        };
        chain.* = .{ .before = guidance_items, .after = guidance_items };
    }
    const patch = try arena.alloc(u8, limits.max_review_units * 2);
    @memset(patch, 'p');
    return buildSuccess(output_allocator, arena, testTarget(), patch, .{
        .files = files,
        .patch_size = @intCast(patch.len),
        .hunk_count = limits.max_review_units,
    }, .{
        .chains = chains,
        .instruction_set_digest = identity.Sha256Digest.hash("gitframe-ai-review-instructions-v1\x00"),
        .unique_source_count = 1,
        .unique_content_bytes = @intCast(guidance_content.len),
    }, violation);
}

fn termExited(term: std.process.Child.Term, expected: u8) bool {
    return switch (term) {
        .exited => |code| code == expected,
        else => false,
    };
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn runTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, result);
    if (!termExited(result.term, 0)) return error.GitCommandFailed;
}

fn testGitOutput(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    errdefer freeRunResult(std.testing.allocator, result);
    if (!termExited(result.term, 0)) {
        freeRunResult(std.testing.allocator, result);
        return error.GitCommandFailed;
    }
    std.testing.allocator.free(result.stderr);
    return result.stdout;
}

test "AI review input materializer emits deterministic complete plan and units" {
    const patch = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/ai-review-producer-v1/input/valid-modified.patch", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(patch);
    var arena_owner = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_owner.deinit();
    const arena = arena_owner.allocator();
    const parsed = try patch_plan.parse(arena, .sha1, patch);
    const empty_chains = try arena.alloc(instructions.FileChains, 1);
    empty_chains[0] = .{ .before = &.{}, .after = &.{} };
    const guidance: instructions.Materialized = .{
        .chains = empty_chains,
        .instruction_set_digest = identity.Sha256Digest.hash("gitframe-ai-review-instructions-v1\x00"),
        .unique_source_count = 0,
        .unique_content_bytes = 0,
    };
    var violation: ?limits.Violation = null;
    var first = try buildSuccess(std.testing.allocator, arena, testTarget(), patch, parsed, guidance, &violation);
    defer first.deinit(std.testing.allocator);
    var second = try buildSuccess(std.testing.allocator, arena, testTarget(), patch, parsed, guidance, &violation);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first.bytes, second.bytes);
    const one_output_digest = identity.Sha256Digest.hash(first.bytes).canonical();
    try std.testing.expectEqualStrings("sha256:db6f405edca16ba2e804e6f252056de20c0847887e8cdceaa3dc907be42e7095", &one_output_digest);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "\"unit_id\":\"unit-0001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "\"start\":0") != null);
    try std.testing.expectEqual(@as(u8, '\n'), first.bytes[first.bytes.len - 1]);
    try std.testing.expect(std.mem.indexOfScalar(u8, first.bytes[0 .. first.bytes.len - 1], '\n') == null);

    const raw_patch = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/ai-review-producer-v1/input/raw-path.patch", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(raw_patch);
    const raw_parsed = try patch_plan.parse(arena, .sha1, raw_patch);
    var raw_output = try buildSuccess(std.testing.allocator, arena, testTarget(), raw_patch, raw_parsed, guidance, &violation);
    defer raw_output.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, raw_output.bytes, "\"old_path_bytes_b64\":\"cmF3_y50eHQ\"") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, raw_output.bytes, 0xff) == null);

    const max_location_patch = "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -4294967295 +4294967295 @@\n-old\n+new\n";
    const max_location_parsed = try patch_plan.parse(arena, .sha1, max_location_patch);
    var max_location_output = try buildSuccess(std.testing.allocator, arena, testTarget(), max_location_patch, max_location_parsed, guidance, &violation);
    defer max_location_output.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, max_location_output.bytes, "\"old_start\":4294967295") != null);
    try std.testing.expect(std.mem.indexOf(u8, max_location_output.bytes, "\"before_location\":\"b0001\"") != null);
}

test "AI review input materializer emits canonical many-unit digests order coverage" {
    const fixture_paths = [_][]const u8{
        "testdata/ai-review-producer-v1/input/valid-modified.patch",
        "testdata/ai-review-producer-v1/input/valid-added.patch",
        "testdata/ai-review-producer-v1/input/valid-deleted.patch",
        "testdata/ai-review-producer-v1/input/valid-renamed.patch",
    };
    var patch_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer patch_writer.deinit();
    var expected_ends: [fixture_paths.len]usize = undefined;
    for (fixture_paths, 0..) |path, index| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4096));
        defer std.testing.allocator.free(bytes);
        try patch_writer.writer.writeAll(bytes);
        expected_ends[index] = patch_writer.written().len;
    }
    var arena_owner = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_owner.deinit();
    const arena = arena_owner.allocator();
    const parsed_patch = try patch_plan.parse(arena, .sha1, patch_writer.written());
    const chains = try arena.alloc(instructions.FileChains, fixture_paths.len);
    for (chains) |*chain| chain.* = .{ .before = &.{}, .after = &.{} };
    const guidance: instructions.Materialized = .{
        .chains = chains,
        .instruction_set_digest = identity.Sha256Digest.hash("gitframe-ai-review-instructions-v1\x00"),
        .unique_source_count = 0,
        .unique_content_bytes = 0,
    };
    var violation: ?limits.Violation = null;
    var output = try buildSuccess(std.testing.allocator, arena, testTarget(), patch_writer.written(), parsed_patch, guidance, &violation);
    defer output.deinit(std.testing.allocator);
    var document = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.bytes, .{});
    defer document.deinit();
    const summary = document.value.object.get("summary").?.object;
    const units = document.value.object.get("units").?.array.items;
    const output_digest = identity.Sha256Digest.hash(output.bytes).canonical();
    try std.testing.expectEqualStrings("sha256:8945cef674c4f2bfba14d33ce7e8b313020762aa53b20f33095e87397a58736a", summary.get("projection_digest").?.string);
    try std.testing.expectEqualStrings("sha256:d1ae83c8db0661d582ce1987c5e8fb7d881b0fa9af10e6e171571b12a22af9a5", summary.get("instruction_set_digest").?.string);
    try std.testing.expectEqualStrings("sha256:792b6558fcb8a1d39ce083dc73ceecd2c78fcad4ed178588bd3c8e1df5709dcd", summary.get("plan_digest").?.string);
    try std.testing.expectEqualStrings("sha256:b2a7272462b0df1a6ba6efca172482c4621a3018811c5e56ae06126c7c5f966c", &output_digest);

    try std.testing.expectEqual(fixture_paths.len, units.len);
    const expected_statuses = [_][]const u8{ "modified", "added", "deleted", "renamed" };
    var coverage_cursor: usize = 0;
    for (units, 0..) |unit_value, index| {
        const unit = unit_value.object;
        try std.testing.expectEqual(@as(i64, @intCast(index + 1)), unit.get("ordinal").?.integer);
        try std.testing.expectEqual(@as(i64, fixture_paths.len), unit.get("unit_count").?.integer);
        try std.testing.expectEqualStrings(expected_statuses[index], unit.get("file_status").?.string);
        const spans = unit.get("coverage_spans").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), spans.len);
        try std.testing.expectEqual(@as(i64, @intCast(coverage_cursor)), spans[0].object.get("start").?.integer);
        try std.testing.expectEqual(@as(i64, @intCast(expected_ends[index])), spans[0].object.get("end_exclusive").?.integer);
        coverage_cursor = expected_ends[index];

        try std.testing.expect(unit.get("locations") == null);
        const hunks = unit.get("hunks").?.array.items;
        var next_before: u16 = 1;
        var next_after: u16 = 1;
        for (hunks) |hunk_value| for (hunk_value.object.get("lines").?.array.items) |line_value| {
            const line = line_value.object;
            const kind = line.get("kind").?.string;
            const before = line.get("before_location");
            const after = line.get("after_location");
            try std.testing.expect((std.mem.eql(u8, kind, "added") and before == null and after != null) or
                (std.mem.eql(u8, kind, "removed") and before != null and after == null) or
                (std.mem.eql(u8, kind, "context") and before != null and after != null));
            if (before) |location_id| {
                const id = try protocol.LocationId.parse(location_id.string);
                try std.testing.expectEqual(protocol.LocationId{ .side = .before, .ordinal = next_before }, id);
                next_before += 1;
            }
            if (after) |location_id| {
                const id = try protocol.LocationId.parse(location_id.string);
                try std.testing.expectEqual(protocol.LocationId{ .side = .after, .ordinal = next_after }, id);
                next_after += 1;
            }
        };
    }
    try std.testing.expectEqual(patch_writer.written().len, coverage_cursor);
}

test "AI review input materializer reports no-change without issuing a unit" {
    var arena_owner = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_owner.deinit();
    const arena = arena_owner.allocator();
    const parsed = try patch_plan.parse(arena, .sha1, "");
    const guidance: instructions.Materialized = .{
        .chains = &.{},
        .instruction_set_digest = identity.Sha256Digest.hash("gitframe-ai-review-instructions-v1\x00"),
        .unique_source_count = 0,
        .unique_content_bytes = 0,
    };
    var violation: ?limits.Violation = null;
    var output = try buildSuccess(std.testing.allocator, arena, testTarget(), "", parsed, guidance, &violation);
    defer output.deinit(std.testing.allocator);
    const zero_output_digest = identity.Sha256Digest.hash(output.bytes).canonical();
    try std.testing.expectEqualStrings("sha256:3d96401ee74066a67578690650a096a0dd99f8dc1b5c57652928b7354d301236", &zero_output_digest);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "\"unit_count\":0") != null);
    try std.testing.expect(std.mem.endsWith(u8, output.bytes, "\"units\":[]}\n"));
}

test "AI review input chunk planner packs only whole hunks around its raw-fragment target" {
    const line = [_]patch_plan.Line{.{ .kind = .context, .text = "x", .line_ending = .lf }};
    const hunks = [_]patch_plan.Hunk{
        .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .section = null, .lines = &line, .coverage = .{ .start = 10, .end_exclusive = 40_000 } },
        .{ .old_start = 2, .old_count = 1, .new_start = 2, .new_count = 1, .section = null, .lines = &line, .coverage = .{ .start = 40_000, .end_exclusive = 80_000 } },
    };
    const file: patch_plan.File = .{
        .old_path = "a",
        .new_path = "a",
        .display_path = "a",
        .status = .modified,
        .metadata_lines = &.{"diff --git a/a b/a"},
        .metadata_coverage = .{ .start = 0, .end_exclusive = 10 },
        .hunks = &hunks,
    };
    var arena_owner = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_owner.deinit();
    var violation: ?limits.Violation = null;
    const chunks = try planChunks(arena_owner.allocator(), .{ .files = &.{file}, .patch_size = 80_000, .hunk_count = 2 }, &violation);
    try std.testing.expectEqual(@as(usize, 2), chunks.len);
    try std.testing.expectEqual(@as(u32, 0), chunks[0].coverage.start);
    try std.testing.expectEqual(@as(u32, 40_000), chunks[0].coverage.end_exclusive);
    try std.testing.expectEqual(@as(u32, 40_000), chunks[1].coverage.start);
    try std.testing.expectEqual(@as(u32, 80_000), chunks[1].coverage.end_exclusive);

    const over_target_hunk = [_]patch_plan.Hunk{.{
        .old_start = 1,
        .old_count = 1,
        .new_start = 1,
        .new_count = 1,
        .section = null,
        .lines = &line,
        .coverage = .{ .start = 1, .end_exclusive = limits.unit_raw_fragment_target_bytes + 1 },
    }};
    const over_target_file: patch_plan.File = .{
        .old_path = "a",
        .new_path = "a",
        .display_path = "a",
        .status = .modified,
        .metadata_lines = &.{"diff --git a/a b/a"},
        .metadata_coverage = .{ .start = 0, .end_exclusive = 1 },
        .hunks = &over_target_hunk,
    };
    violation = null;
    const over_target_chunks = try planChunks(arena_owner.allocator(), .{
        .files = &.{over_target_file},
        .patch_size = limits.unit_raw_fragment_target_bytes + 1,
        .hunk_count = 1,
    }, &violation);
    try std.testing.expectEqual(@as(usize, 1), over_target_chunks.len);
    try std.testing.expectEqual(@as(u32, limits.unit_raw_fragment_target_bytes + 1), over_target_chunks[0].coverage.end_exclusive);
    try std.testing.expect(violation == null);

    const files = try arena_owner.allocator().alloc(patch_plan.File, limits.max_review_units + 1);
    const one_hunk = try arena_owner.allocator().alloc(patch_plan.Hunk, limits.max_review_units + 1);
    for (files, one_hunk, 0..) |*current_file, *current_hunk, index| {
        const start: u32 = @intCast(index * 2);
        current_hunk.* = .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .section = null, .lines = &line, .coverage = .{ .start = start + 1, .end_exclusive = start + 2 } };
        current_file.* = .{ .old_path = "a", .new_path = "a", .display_path = "a", .status = .modified, .metadata_lines = &.{"diff --git a/a b/a"}, .metadata_coverage = .{ .start = start, .end_exclusive = start + 1 }, .hunks = one_hunk[index .. index + 1] };
    }
    violation = null;
    try std.testing.expectError(error.LimitExceeded, planChunks(arena_owner.allocator(), .{
        .files = files,
        .patch_size = @intCast(files.len * 2),
        .hunk_count = @intCast(files.len),
    }, &violation));
}

test "AI review input materializer fixes per-unit guidance and complete-output exact plus-one limits" {
    const content_line = [_]patch_plan.Line{.{ .kind = .context, .text = "x", .line_ending = .lf }};
    const hunk = [_]patch_plan.Hunk{.{
        .old_start = 1,
        .old_count = 1,
        .new_start = 1,
        .new_count = 1,
        .section = null,
        .lines = &content_line,
        .coverage = .{ .start = 1, .end_exclusive = 2 },
    }};
    const file: patch_plan.File = .{
        .old_path = "a",
        .new_path = "a",
        .display_path = "a",
        .status = .modified,
        .metadata_lines = &.{"diff --git a/a b/a"},
        .metadata_coverage = .{ .start = 0, .end_exclusive = 1 },
        .hunks = &hunk,
    };
    const exact_content = try std.testing.allocator.alloc(u8, limits.max_guidance_per_unit_bytes);
    defer std.testing.allocator.free(exact_content);
    @memset(exact_content, 'g');
    const plus_content = try std.testing.allocator.alloc(u8, limits.max_guidance_per_unit_bytes + 1);
    defer std.testing.allocator.free(plus_content);
    @memset(plus_content, 'g');
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const exact_item: protocol.Guidance = .{ .head_oid = oid, .path_bytes = "AGENTS.md", .blob_oid = oid, .content_digest = identity.Sha256Digest.hash(exact_content), .content = exact_content };
    const plus_item: protocol.Guidance = .{ .head_oid = oid, .path_bytes = "AGENTS.md", .blob_oid = oid, .content_digest = identity.Sha256Digest.hash(plus_content), .content = plus_content };
    const chunk: Chunk = .{ .file_index = 0, .hunk_start = 0, .hunk_end = 1, .coverage = .{ .start = 0, .end_exclusive = 2 } };
    var arena_owner = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_owner.deinit();
    var violation: ?limits.Violation = null;
    _ = try buildUnit(arena_owner.allocator(), file, .{ .before = &.{exact_item}, .after = &.{} }, chunk, 1, 1, identity.Sha256Digest.hash("plan"), &violation);
    try std.testing.expect(violation == null);
    try std.testing.expectError(error.LimitExceeded, buildUnit(arena_owner.allocator(), file, .{ .before = &.{plus_item}, .after = &.{} }, chunk, 1, 1, identity.Sha256Digest.hash("plan"), &violation));
    try std.testing.expectEqualStrings("guidance_per_unit_bytes", violation.?.resource);
    try std.testing.expectEqual(limits.max_guidance_per_unit_bytes + 1, violation.?.observed);
    try std.testing.expectEqual(limits.max_guidance_per_unit_bytes, violation.?.allowed);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try output.resize(std.testing.allocator, limits.max_review_input_output_bytes - 1);
    @memset(output.items, 'x');
    violation = null;
    try appendBounded(std.testing.allocator, &output, "x", &violation);
    try std.testing.expectEqual(limits.max_review_input_output_bytes, output.items.len);
    try std.testing.expect(violation == null);
    try std.testing.expectError(error.LimitExceeded, appendBounded(std.testing.allocator, &output, "x", &violation));
    try std.testing.expectEqualStrings("input_output_bytes", violation.?.resource);
    try std.testing.expectEqual(limits.max_review_input_output_bytes + 1, violation.?.observed);
    try std.testing.expectEqual(limits.max_review_input_output_bytes, violation.?.allowed);
}

test "AI review input materializer builds exact 32 MiB canonical output and reports plus one" {
    var violation: ?limits.Violation = null;
    var baseline = try testBuildLargeCanonicalOutput(std.testing.allocator, 0, 0, &violation);
    defer baseline.deinit(std.testing.allocator);
    try std.testing.expect(baseline.bytes.len < limits.max_review_input_output_bytes);
    const newline_step = 2 * limits.max_review_units;
    const remaining = limits.max_review_input_output_bytes - baseline.bytes.len;
    const newline_count = remaining / newline_step;
    const metadata_extra = remaining % newline_step;
    try std.testing.expect(newline_count <= limits.max_guidance_per_unit_bytes / 2);
    var exact = try testBuildLargeCanonicalOutput(std.testing.allocator, newline_count, metadata_extra, &violation);
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqual(limits.max_review_input_output_bytes, exact.bytes.len);
    violation = null;
    try std.testing.expectError(error.LimitExceeded, testBuildLargeCanonicalOutput(std.testing.allocator, newline_count, metadata_extra + 1, &violation));
    try std.testing.expectEqualStrings("input_output_bytes", violation.?.resource);
    try std.testing.expectEqual(limits.max_review_input_output_bytes + 1, violation.?.observed);
    try std.testing.expectEqual(limits.max_review_input_output_bytes, violation.?.allowed);
    var terminal = try errorOutput(std.testing.allocator, limitFailure(violation.?));
    defer terminal.deinit(std.testing.allocator);
    try expectLimitTerminal(terminal, "review_input_limit_exceeded", "review-input exceeded a finite v1 resource limit", "input_output_bytes", limits.max_review_input_output_bytes + 1, limits.max_review_input_output_bytes);
}

test "AI review input command rejects arguments before frame admission" {
    var output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{"--help"}, &.{});
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), output.exit_code);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"status\":\"error\",\"error\":{\"code\":\"invalid_arguments\",\"message\":\"review-input accepts no arguments\"}}\n",
        output.bytes,
    );
    var limited = try errorOutput(std.testing.allocator, limitFailure(.{
        .resource = "changed_files",
        .observed = limits.max_changed_files + 1,
        .allowed = limits.max_changed_files,
    }));
    defer limited.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"status\":\"error\",\"error\":{\"code\":\"review_input_limit_exceeded\",\"message\":\"review-input exceeded a finite v1 resource limit\",\"resource\":\"changed_files\",\"observed\":1025,\"allowed\":1024}}\n",
        limited.bytes,
    );
}

test "AI review input command reports exact process terminals for owner boundary plus-one inputs" {
    const target = testTarget();
    const generic_message = "review-input exceeded a finite v1 resource limit";
    const oversized_request = try std.testing.allocator.alloc(u8, max_request_bytes + 1);
    defer std.testing.allocator.free(oversized_request);
    @memset(oversized_request, 'x');
    var output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{}, oversized_request);
    try expectLimitTerminal(output, "review_input_limit_exceeded", generic_message, "review_input_frame_bytes", max_request_bytes + 1, max_request_bytes);
    output.deinit(std.testing.allocator);

    const oversized_header = try std.testing.allocator.alloc(u8, limits.max_input_header_bytes + 1);
    defer std.testing.allocator.free(oversized_header);
    @memset(oversized_header, 'x');
    oversized_header[oversized_header.len - 1] = '\n';
    output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{}, oversized_header);
    try expectLimitTerminal(output, "review_input_limit_exceeded", generic_message, "input_header_bytes", limits.max_input_header_bytes + 1, limits.max_input_header_bytes);
    output.deinit(std.testing.allocator);

    const target_json = try testTargetJson(std.testing.allocator, &target);
    defer std.testing.allocator.free(target_json);
    const short_inner = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":0}}\n", .{target_json});
    defer std.testing.allocator.free(short_inner);
    const oversized_frame = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, limits.max_projection_frame_bytes + 1, short_inner });
    defer std.testing.allocator.free(oversized_frame);
    output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{}, oversized_frame);
    try expectLimitTerminal(output, "review_input_limit_exceeded", generic_message, "projection_frame_bytes", limits.max_projection_frame_bytes + 1, limits.max_projection_frame_bytes);
    output.deinit(std.testing.allocator);

    const oversized_projection = try std.testing.allocator.alloc(u8, limits.max_projection_bytes + 1);
    defer std.testing.allocator.free(oversized_projection);
    @memset(oversized_projection, 'x');
    const projection_request = try reviewInputRequestAlloc(std.testing.allocator, "/tmp/repo", &target, oversized_projection);
    defer std.testing.allocator.free(projection_request);
    output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{}, projection_request);
    try expectLimitTerminal(output, "review_input_limit_exceeded", generic_message, "projection_bytes", limits.max_projection_bytes + 1, limits.max_projection_bytes);
    output.deinit(std.testing.allocator);

    var changed_files: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer changed_files.deinit();
    for (0..limits.max_changed_files + 1) |index| try changed_files.writer.print(
        "diff --git a/f{d} b/f{d}\nindex 1111111..2222222 100644\n--- a/f{d}\n+++ b/f{d}\n@@ -1 +1 @@\n-old\n+new\n",
        .{ index, index, index, index },
    );
    const files_request = try reviewInputRequestAlloc(std.testing.allocator, "/tmp/repo", &target, changed_files.written());
    defer std.testing.allocator.free(files_request);
    output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{}, files_request);
    try expectLimitTerminal(output, "review_input_limit_exceeded", generic_message, "changed_files", limits.max_changed_files + 1, limits.max_changed_files);
    output.deinit(std.testing.allocator);

    var hunks: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer hunks.deinit();
    try hunks.writer.writeAll("diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n");
    for (0..limits.max_hunks + 1) |index| try hunks.writer.print("@@ -{d} +{d} @@\n-old\n+new\n", .{ index + 1, index + 1 });
    const hunks_request = try reviewInputRequestAlloc(std.testing.allocator, "/tmp/repo", &target, hunks.written());
    defer std.testing.allocator.free(hunks_request);
    output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{}, hunks_request);
    try expectLimitTerminal(output, "review_input_limit_exceeded", generic_message, "hunks", limits.max_hunks + 1, limits.max_hunks);
    output.deinit(std.testing.allocator);
}

test "AI review input command accepts an indivisible over-target hunk without a raw-fragment terminal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "seed\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "a" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });
    const head_text = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_text);
    const oid = try target_mod.ObjectId.parse(.sha1, std.mem.trimEnd(u8, head_text, "\n"));
    const target: target_mod.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = oid,
        .head_oid = oid,
        .diff_base_oid = oid,
    };
    const repository = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repository);
    const patch_bytes = try testPatchWithRawHunkSize(std.testing.allocator, limits.unit_raw_fragment_target_bytes + 1);
    defer std.testing.allocator.free(patch_bytes);
    const request = try reviewInputRequestAlloc(std.testing.allocator, repository, &target, patch_bytes);
    defer std.testing.allocator.free(request);
    var output = try executeAlloc(std.testing.allocator, io, null, &.{}, request);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "\"unit_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "{\"name\":\"unit_raw_fragment_target_bytes\",\"value\":65536}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "unit_raw_fragment_bytes") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "review_unit_too_large") == null);
}

test "AI review input command admits the exact no-change frame without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repository = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repository);
    const target = testTarget();
    const request = try reviewInputRequestAlloc(std.testing.allocator, repository, &target, "");
    defer std.testing.allocator.free(request);
    var output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{}, request);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "\"unit_count\":0") != null);
}

test "AI review input command rejects noncanonical outer inner and nested frame bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repository = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repository);
    const encoded = try std.testing.allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(repository.len));
    defer std.testing.allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, repository);
    const target = testTarget();
    const target_json = try testTargetJson(std.testing.allocator, &target);
    defer std.testing.allocator.free(target_json);
    const reordered_target = "{\"source_kind\":\"branch_range\",\"object_format\":\"sha1\",\"base_oid\":\"0123456789abcdef0123456789abcdef01234567\",\"head_oid\":\"0123456789abcdef0123456789abcdef01234567\",\"diff_base_oid\":\"0123456789abcdef0123456789abcdef01234567\"}";
    const canonical_inner = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":0}}\n", .{target_json});
    defer std.testing.allocator.free(canonical_inner);

    const inner_headers = [_][]const u8{
        try std.fmt.allocPrint(std.testing.allocator, "{{\"status\":\"ok\",\"schema_version\":1,\"target\":{s},\"patch_size\":0}}\n", .{target_json}),
        try std.fmt.allocPrint(std.testing.allocator, "{{ \"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":0}}\n", .{target_json}),
        try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"\\u006fk\",\"target\":{s},\"patch_size\":0}}\n", .{target_json}),
        try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":0}}\n", .{reordered_target}),
    };
    defer for (inner_headers) |bytes| std.testing.allocator.free(bytes);
    for (inner_headers) |inner| {
        const request = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"{s}\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ encoded, target_json, inner.len, inner });
        defer std.testing.allocator.free(request);
        var output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{}, request);
        defer output.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 2), output.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, output.bytes, "\"code\":\"invalid_review_input_frame\"") != null);
    }

    const outer_headers = [_][]const u8{
        try std.fmt.allocPrint(std.testing.allocator, "{{\"repository\":{{\"path_bytes_b64\":\"{s}\"}},\"schema_version\":1,\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ encoded, target_json, canonical_inner.len, canonical_inner }),
        try std.fmt.allocPrint(std.testing.allocator, "{{ \"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"{s}\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ encoded, target_json, canonical_inner.len, canonical_inner }),
        try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"{s}\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ encoded, reordered_target, canonical_inner.len, canonical_inner }),
        try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXB\\u0076\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, canonical_inner.len, canonical_inner }),
    };
    defer for (outer_headers) |bytes| std.testing.allocator.free(bytes);
    for (outer_headers) |request| {
        var output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{}, request);
        defer output.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 2), output.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, output.bytes, "\"code\":\"invalid_review_input_frame\"") != null);
    }
}

test "AI review input command maps malformed patch records to exit 2 and explicit nonregular mode to exit 5" {
    const malformed = [_][]const u8{
        "diff --git a/evil.txt b/good.txt\nnew file mode 100644\nindex 0000000..2222222\n--- /dev/null\n+++ b/good.txt\n@@ -0,0 +1 @@\n+good\n",
        "diff --git a/link b/link\n--- a/link\n+++ b/link\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nnew file mode 100644\nindex 0000000..2222222\n--- /dev/null\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nnew file mode invalid\nindex 0000000..2222222\n--- /dev/null\n+++ b/a\n@@ -0,0 +1 @@\n+new\n",
        "diff --git a/old b/new\nsimilarity index injected 50%\nrename from old\nrename to new\nindex 1111111..2222222 100644\n--- a/old\n+++ b/new\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..1111111 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -4294967295,2 +1,2 @@\n-old one\n-old two\n+new one\n+new two\n",
        "diff --git a/a  b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1 +1@@\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@section\n-old\n+new\n",
        "diff --git \"a/a\" \"b/a\"\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1,1 +1 @@\n-old\n+new\n",
    };
    const target = testTarget();
    for (malformed) |patch| {
        const request = try reviewInputRequestAlloc(std.testing.allocator, "/tmp/repo", &target, patch);
        defer std.testing.allocator.free(request);
        var output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{}, request);
        defer output.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 2), output.exit_code);
        try std.testing.expectEqualStrings("{\"schema_version\":1,\"status\":\"error\",\"error\":{\"code\":\"invalid_projection\",\"message\":\"projection is not one complete canonical Git patch\"}}\n", output.bytes);
    }

    const nonregular = "diff --git a/link b/link\nnew file mode 120000\nindex 0000000..2222222\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+target\n";
    const request = try reviewInputRequestAlloc(std.testing.allocator, "/tmp/repo", &target, nonregular);
    defer std.testing.allocator.free(request);
    var output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{}, request);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 5), output.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "\"code\":\"unsupported_projection\"") != null);
}

test "AI review input command public OID boundary matches SHA-1 and SHA-256 actual Git writers" {
    const format_cases = [_]target_mod.ObjectFormat{ .sha1, .sha256 };
    const old_plus = [_]u8{'1'} ** 65;
    const new_plus = [_]u8{'2'} ** 65;

    for (format_cases) |object_format| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const io = std.testing.io;
        const object_format_option = if (object_format == .sha1) "--object-format=sha1" else "--object-format=sha256";
        try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main", object_format_option });
        try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "old\n" });
        try runTestGit(io, tmp.dir, &.{ "git", "add", "a.txt" });
        try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
        const base_text = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
        defer std.testing.allocator.free(base_text);
        try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "new\n" });
        try runTestGit(io, tmp.dir, &.{ "git", "add", "a.txt" });
        try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });
        const head_text = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
        defer std.testing.allocator.free(head_text);
        const base_oid = try target_mod.ObjectId.parse(object_format, std.mem.trimEnd(u8, base_text, "\n"));
        const head_oid = try target_mod.ObjectId.parse(object_format, std.mem.trimEnd(u8, head_text, "\n"));
        const target: target_mod.CommittedReviewTarget = .{
            .object_format = object_format,
            .source_kind = .branch_range,
            .base_oid = base_oid,
            .head_oid = head_oid,
            .diff_base_oid = base_oid,
        };
        const attr_source = try std.fmt.allocPrint(std.testing.allocator, "--attr-source={s}", .{head_oid.slice()});
        defer std.testing.allocator.free(attr_source);
        const repository = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
        defer std.testing.allocator.free(repository);
        const requested_widths = [_]usize{
            object_format.oidHexLength(),
            object_format.oidHexLength() + 1,
        };
        for (requested_widths) |requested_width| {
            const abbrev_option = try std.fmt.allocPrint(std.testing.allocator, "core.abbrev={d}", .{requested_width});
            defer std.testing.allocator.free(abbrev_option);
            const patch = try testGitOutput(io, tmp.dir, &.{
                "git",             "-c",                  abbrev_option,    "--no-replace-objects",
                "--no-lazy-fetch", "--no-optional-locks", attr_source,      "diff",
                "--no-color",      "--no-ext-diff",       "--no-textconv",  "--src-prefix=a/",
                "--dst-prefix=b/", base_oid.slice(),      head_oid.slice(),
            });
            defer std.testing.allocator.free(patch);

            const index_start = std.mem.indexOf(u8, patch, "index ").? + "index ".len;
            const pair_end = std.mem.indexOfScalarPos(u8, patch, index_start, ' ').?;
            const pair = patch[index_start..pair_end];
            const dots = std.mem.indexOf(u8, pair, "..").?;
            try std.testing.expectEqual(object_format.oidHexLength(), pair[0..dots].len);
            try std.testing.expectEqual(object_format.oidHexLength(), pair[dots + 2 ..].len);

            const exact_request = try reviewInputRequestAlloc(std.testing.allocator, repository, &target, patch);
            defer std.testing.allocator.free(exact_request);
            var exact_output = try executeAlloc(std.testing.allocator, io, null, &.{}, exact_request);
            defer exact_output.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(u8, 0), exact_output.exit_code);
            try std.testing.expect(std.mem.indexOf(u8, exact_output.bytes, "\"unit_count\":1") != null);
        }

        const plus_width = object_format.oidHexLength() + 1;
        const plus_patch = try std.fmt.allocPrint(
            std.testing.allocator,
            "diff --git a/a.txt b/a.txt\nindex {s}..{s} 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n",
            .{ old_plus[0..plus_width], new_plus[0..plus_width] },
        );
        defer std.testing.allocator.free(plus_patch);
        const plus_request = try reviewInputRequestAlloc(std.testing.allocator, repository, &target, plus_patch);
        defer std.testing.allocator.free(plus_request);
        var plus_output = try executeAlloc(std.testing.allocator, io, null, &.{}, plus_request);
        defer plus_output.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 2), plus_output.exit_code);
        try std.testing.expectEqualStrings(
            "{\"schema_version\":1,\"status\":\"error\",\"error\":{\"code\":\"invalid_projection\",\"message\":\"projection is not one complete canonical Git patch\"}}\n",
            plus_output.bytes,
        );
    }
}

test "AI review input command projects committed guidance and ignores staged dirty and untracked files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.createDir(io, "src", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "root guidance\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/AGENTS.md", .data = "nested guidance\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.txt", .data = "old\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "AGENTS.md", "src/AGENTS.md", "src/a.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    const head_text = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_text);
    const oid = try target_mod.ObjectId.parse(.sha1, std.mem.trimEnd(u8, head_text, "\n"));
    const target: target_mod.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = oid,
        .head_oid = oid,
        .diff_base_oid = oid,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "staged replacement\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "AGENTS.md" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/AGENTS.md", .data = "dirty replacement\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/OTHER.md", .data = "untracked instructions\n" });
    const repository = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repository);
    const patch =
        "diff --git a/src/a.txt b/src/a.txt\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/src/a.txt\n" ++
        "+++ b/src/a.txt\n" ++
        "@@ -1 +1 @@\n-old\n+new\n";
    const request = try reviewInputRequestAlloc(std.testing.allocator, repository, &target, patch);
    defer std.testing.allocator.free(request);
    var output = try executeAlloc(std.testing.allocator, io, null, &.{}, request);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "root guidance\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "nested guidance\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "replacement") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "untracked instructions") == null);
}

test "AI review input command admits actual review-projection modify add delete and rename output" {
    const format_cases = [_]target_mod.ObjectFormat{ .sha1, .sha256 };
    for (format_cases) |object_format| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const io = std.testing.io;
        const object_format_option = if (object_format == .sha1) "--object-format=sha1" else "--object-format=sha256";
        try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main", object_format_option });
        try tmp.dir.writeFile(io, .{ .sub_path = "modify.txt", .data = "old\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "gone.txt", .data = "gone\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "old-name.txt", .data = "same one\nsame two\nold three\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "copy-source.txt", .data = "copy one\ncopy two\nold copy three\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "function.c", .data = "int main(void) {\n    int one = 1;\n    int two = 2;\n    int three = 3;\n    int four = 4;\n    return one + two + three + four;\n}\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "space name.txt", .data = "old space\n" });
        const raw_path = "raw-\xff.txt";
        try tmp.dir.writeFile(io, .{ .sub_path = raw_path, .data = "old raw\n" });
        try runTestGit(io, tmp.dir, &.{ "git", "add", "modify.txt", "gone.txt", "old-name.txt", "copy-source.txt", "function.c", "space name.txt", raw_path });
        try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
        const base_text = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
        defer std.testing.allocator.free(base_text);
        try tmp.dir.writeFile(io, .{ .sub_path = "modify.txt", .data = "new\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "fresh.txt", .data = "fresh\n" });
        try tmp.dir.deleteFile(io, "gone.txt");
        try tmp.dir.rename("old-name.txt", tmp.dir, "new-name.txt", io);
        try tmp.dir.writeFile(io, .{ .sub_path = "new-name.txt", .data = "same one\nsame two\nnew three\n" });
        const copied_content = "copy one\ncopy two\nnew copy three\n";
        try tmp.dir.writeFile(io, .{ .sub_path = "copy-source.txt", .data = copied_content });
        try tmp.dir.writeFile(io, .{ .sub_path = "copy-target.txt", .data = copied_content });
        try tmp.dir.writeFile(io, .{ .sub_path = "function.c", .data = "int main(void) {\n    int one = 1;\n    int two = 2;\n    int three = 3;\n    int four = 4;\n    return one + two + three + four + 5;\n}\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "space name.txt", .data = "new space\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = raw_path, .data = "new raw\n" });
        try runTestGit(io, tmp.dir, &.{ "git", "add", "-A" });
        try runTestGit(io, tmp.dir, &.{ "git", "update-index", "--chmod=+x", "new-name.txt" });
        try runTestGit(io, tmp.dir, &.{ "git", "update-index", "--chmod=+x", "copy-target.txt" });
        try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });
        try runTestGit(io, tmp.dir, &.{ "git", "config", "diff.renames", "copies" });
        try runTestGit(io, tmp.dir, &.{ "git", "config", "core.quotePath", "true" });
        const head_text = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
        defer std.testing.allocator.free(head_text);
        const base_oid = try target_mod.ObjectId.parse(object_format, std.mem.trimEnd(u8, base_text, "\n"));
        const head_oid = try target_mod.ObjectId.parse(object_format, std.mem.trimEnd(u8, head_text, "\n"));
        const target: target_mod.CommittedReviewTarget = .{ .object_format = object_format, .source_kind = .branch_range, .base_oid = base_oid, .head_oid = head_oid, .diff_base_oid = base_oid };
        const attr_source = try std.fmt.allocPrint(std.testing.allocator, "--attr-source={s}", .{head_oid.slice()});
        defer std.testing.allocator.free(attr_source);
        const patch = try testGitOutput(io, tmp.dir, &.{
            "git",             "--no-replace-objects", "--no-lazy-fetch", "--no-optional-locks", attr_source,
            "diff",            "--no-color",           "--no-ext-diff",   "--no-textconv",       "--src-prefix=a/",
            "--dst-prefix=b/", base_oid.slice(),       head_oid.slice(),
        });
        defer std.testing.allocator.free(patch);
        try std.testing.expect(std.mem.indexOf(u8, patch, "old mode 100644\nnew mode 100755\nsimilarity index ") != null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "copy from copy-source.txt\ncopy to copy-target.txt") != null);
        try std.testing.expect(std.mem.indexOf(u8, patch, " @@ int main(void) {") != null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "diff --git a/space name.txt b/space name.txt") != null);
        try std.testing.expect(std.mem.indexOf(u8, patch, "raw-\\377.txt") != null);
        var arena_owner = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_owner.deinit();
        const parsed = try patch_plan.parse(arena_owner.allocator(), object_format, patch);
        try std.testing.expectEqual(@as(usize, 9), parsed.files.len);
        var statuses = [_]bool{false} ** 5;
        for (parsed.files) |file| statuses[@intFromEnum(file.status)] = true;
        for (statuses) |present| try std.testing.expect(present);
        for (parsed.files) |file| if (file.status == .renamed) {
            try std.testing.expectEqual(@as(usize, 9), file.metadata_lines.len);
            try std.testing.expectEqualStrings("old mode 100644", file.metadata_lines[1]);
            try std.testing.expectEqualStrings("new mode 100755", file.metadata_lines[2]);
            try std.testing.expect(std.mem.startsWith(u8, file.metadata_lines[3], "similarity index "));
            try std.testing.expectEqualStrings("rename from old-name.txt", file.metadata_lines[4]);
            try std.testing.expectEqualStrings("rename to new-name.txt", file.metadata_lines[5]);
        };
        const repository = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
        defer std.testing.allocator.free(repository);
        const request = try reviewInputRequestAlloc(std.testing.allocator, repository, &target, patch);
        defer std.testing.allocator.free(request);
        var output = try executeAlloc(std.testing.allocator, io, null, &.{}, request);
        defer output.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), output.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, output.bytes, "\"unit_count\":9") != null);
        var document = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.bytes, .{});
        defer document.deinit();
        const summary = document.value.object.get("summary").?.object;
        const units = document.value.object.get("units").?.array.items;
        const expected_projection_digest = identity.Sha256Digest.hash(patch).canonical();
        try std.testing.expectEqualStrings(&expected_projection_digest, summary.get("projection_digest").?.string);
        var coverage_cursor: i64 = 0;
        var saw_renamed = false;
        for (units) |unit_value| {
            const unit = unit_value.object;
            try std.testing.expectEqualStrings(summary.get("plan_digest").?.string, unit.get("plan_digest").?.string);
            const spans = unit.get("coverage_spans").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), spans.len);
            try std.testing.expectEqual(coverage_cursor, spans[0].object.get("start").?.integer);
            coverage_cursor = spans[0].object.get("end_exclusive").?.integer;
            if (std.mem.eql(u8, unit.get("file_status").?.string, "renamed")) {
                saw_renamed = true;
                try std.testing.expect(unit.get("locations") == null);
                const hunks = unit.get("hunks").?.array.items;
                var next_before: u16 = 1;
                var next_after: u16 = 1;
                for (hunks) |hunk_value| for (hunk_value.object.get("lines").?.array.items) |line_value| {
                    const line = line_value.object;
                    if (line.get("before_location")) |value| {
                        try std.testing.expectEqual(protocol.LocationId{ .side = .before, .ordinal = next_before }, try protocol.LocationId.parse(value.string));
                        next_before += 1;
                    }
                    if (line.get("after_location")) |value| {
                        try std.testing.expectEqual(protocol.LocationId{ .side = .after, .ordinal = next_after }, try protocol.LocationId.parse(value.string));
                        next_after += 1;
                    }
                };
                try std.testing.expectEqual(@as(u16, 4), next_before);
                try std.testing.expectEqual(@as(u16, 4), next_after);
            }
        }
        try std.testing.expect(saw_renamed);
        try std.testing.expectEqual(@as(i64, @intCast(patch.len)), coverage_cursor);

        try runTestGit(io, tmp.dir, &.{ "git", "config", "core.quotePath", "false" });
        const literal_path_patch = try testGitOutput(io, tmp.dir, &.{
            "git",             "--no-replace-objects", "--no-lazy-fetch", "--no-optional-locks", attr_source,
            "diff",            "--no-color",           "--no-ext-diff",   "--no-textconv",       "--src-prefix=a/",
            "--dst-prefix=b/", base_oid.slice(),       head_oid.slice(),
        });
        defer std.testing.allocator.free(literal_path_patch);
        try std.testing.expect(std.mem.indexOf(u8, literal_path_patch, raw_path) != null);
        const literal_request = try reviewInputRequestAlloc(std.testing.allocator, repository, &target, literal_path_patch);
        defer std.testing.allocator.free(literal_request);
        var literal_output = try executeAlloc(std.testing.allocator, io, null, &.{}, literal_request);
        defer literal_output.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), literal_output.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, literal_output.bytes, "\"unit_count\":9") != null);
    }
}

test "AI review input command admits exact per-unit guidance bytes and reports plus one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.createDir(io, "src", .default_dir);
    const root_guidance = try std.testing.allocator.alloc(u8, 32 * 1024);
    defer std.testing.allocator.free(root_guidance);
    @memset(root_guidance, 'r');
    const nested_exact = try std.testing.allocator.alloc(u8, 32 * 1024);
    defer std.testing.allocator.free(nested_exact);
    @memset(nested_exact, 'n');
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = root_guidance });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/AGENTS.md", .data = nested_exact });
    try tmp.dir.writeFile(io, .{ .sub_path = "old.txt", .data = "old\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "AGENTS.md", "src/AGENTS.md", "old.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "exact guidance" });
    const exact_head_text = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(exact_head_text);
    const exact_oid = try target_mod.ObjectId.parse(.sha1, std.mem.trimEnd(u8, exact_head_text, "\n"));
    const exact_target: target_mod.CommittedReviewTarget = .{ .object_format = .sha1, .source_kind = .branch_range, .base_oid = exact_oid, .head_oid = exact_oid, .diff_base_oid = exact_oid };
    const repository = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repository);
    const rename_patch =
        "diff --git a/old.txt b/src/new.txt\n" ++
        "similarity index 50%\n" ++
        "rename from old.txt\n" ++
        "rename to src/new.txt\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/old.txt\n" ++
        "+++ b/src/new.txt\n" ++
        "@@ -1 +1 @@\n-old\n+new\n";
    const exact_request = try reviewInputRequestAlloc(std.testing.allocator, repository, &exact_target, rename_patch);
    defer std.testing.allocator.free(exact_request);
    var exact_output = try executeAlloc(std.testing.allocator, io, null, &.{}, exact_request);
    defer exact_output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), exact_output.exit_code);

    const nested_plus_one = try std.testing.allocator.alloc(u8, 32 * 1024 + 1);
    defer std.testing.allocator.free(nested_plus_one);
    @memset(nested_plus_one, 'n');
    try tmp.dir.writeFile(io, .{ .sub_path = "src/AGENTS.md", .data = nested_plus_one });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "src/AGENTS.md" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "plus one guidance" });
    const plus_head_text = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(plus_head_text);
    const plus_oid = try target_mod.ObjectId.parse(.sha1, std.mem.trimEnd(u8, plus_head_text, "\n"));
    const plus_target: target_mod.CommittedReviewTarget = .{ .object_format = .sha1, .source_kind = .branch_range, .base_oid = plus_oid, .head_oid = plus_oid, .diff_base_oid = plus_oid };
    const plus_request = try reviewInputRequestAlloc(std.testing.allocator, repository, &plus_target, rename_patch);
    defer std.testing.allocator.free(plus_request);
    var plus_output = try executeAlloc(std.testing.allocator, io, null, &.{}, plus_request);
    defer plus_output.deinit(std.testing.allocator);
    try expectLimitTerminal(plus_output, "review_input_limit_exceeded", "review-input exceeded a finite v1 resource limit", "guidance_per_unit_bytes", limits.max_guidance_per_unit_bytes + 1, limits.max_guidance_per_unit_bytes);
}
