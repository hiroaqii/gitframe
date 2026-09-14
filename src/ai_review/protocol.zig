//! Provider-neutral values for deterministic AI review protocol v1.
//!
//! Deterministic helpers own every target, path, location, digest, unit, and
//! stored-batch field. An AI producer supplies only `FindingCandidatePayload`.

const std = @import("std");
const anchor = @import("../committed_review/anchor.zig");
const artifact = @import("../committed_review/artifact.zig");
const identity = @import("../committed_review/identity.zig");
const target_mod = @import("../committed_review/target.zig");
const limits = @import("limits.zig");

/// Canonical `unit-0001` through `unit-0256` identity.
pub const UnitId = struct {
    ordinal: u16,

    pub fn parse(text: []const u8) error{InvalidUnitId}!UnitId {
        if (text.len != 9 or !std.mem.eql(u8, text[0..5], "unit-")) return error.InvalidUnitId;
        const value = fixedDecimal(u16, text[5..9]) catch return error.InvalidUnitId;
        if (value == 0 or value > limits.max_review_units) return error.InvalidUnitId;
        const result: UnitId = .{ .ordinal = value };
        if (!std.mem.eql(u8, text, &result.canonical())) return error.InvalidUnitId;
        return result;
    }

    pub fn canonical(self: UnitId) [9]u8 {
        var bytes = [_]u8{ 'u', 'n', 'i', 't', '-', '0', '0', '0', '0' };
        writeFourDigits(bytes[5..9], self.ordinal);
        return bytes;
    }

    pub fn eql(self: UnitId, other: UnitId) bool {
        return self.ordinal == other.ordinal;
    }
};

/// Canonical unit-local `b0001`/`a0001` location identity.
pub const LocationId = struct {
    side: anchor.AnchorSide,
    ordinal: u16,

    pub fn parse(text: []const u8) error{InvalidLocationId}!LocationId {
        if (text.len != 5) return error.InvalidLocationId;
        const side: anchor.AnchorSide = switch (text[0]) {
            'b' => .before,
            'a' => .after,
            else => return error.InvalidLocationId,
        };
        const value = fixedDecimal(u16, text[1..5]) catch return error.InvalidLocationId;
        if (value == 0 or value > limits.max_locations_per_side) return error.InvalidLocationId;
        const result: LocationId = .{ .side = side, .ordinal = value };
        if (!std.mem.eql(u8, text, &result.canonical())) return error.InvalidLocationId;
        return result;
    }

    pub fn canonical(self: LocationId) [5]u8 {
        var bytes = [_]u8{ if (self.side == .before) 'b' else 'a', '0', '0', '0', '0' };
        writeFourDigits(bytes[1..5], self.ordinal);
        return bytes;
    }

    pub fn eql(self: LocationId, other: LocationId) bool {
        return self.side == other.side and self.ordinal == other.ordinal;
    }
};

/// Exact v1 limit-set marker. Its wire form is the complete named array.
pub const ReviewLimitSet = enum { v1 };

pub const ReviewPlanSummary = struct {
    schema_version: u64,
    target: target_mod.CommittedReviewTarget,
    projection_digest: identity.Sha256Digest,
    instruction_set_digest: identity.Sha256Digest,
    unit_count: u16,
    plan_digest: identity.Sha256Digest,
    limits: ReviewLimitSet,

    pub fn parseStrict(allocator: std.mem.Allocator, bytes: []const u8) @import("codec.zig").ParseError!@import("codec.zig").Parsed(ReviewPlanSummary) {
        return @import("codec.zig").parsePlanSummary(allocator, bytes);
    }

    pub fn writeCanonical(self: *const ReviewPlanSummary, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writePlanSummaryAlloc(allocator, self);
    }
};

pub const FileStatus = enum { added, modified, deleted, renamed, copied };
pub const DiffLineKind = enum { context, removed, added };
pub const LineEnding = enum { lf, crlf, none };

pub const DiffLine = struct {
    kind: DiffLineKind,
    /// UTF-8 committed content without the diff prefix or line terminator.
    text: []const u8,
    line_ending: LineEnding,
    before_location: ?LocationId = null,
    after_location: ?LocationId = null,
};

pub const ReviewHunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    section: ?[]const u8 = null,
    lines: []const DiffLine,
};

/// Unit-local deterministic mapping from opaque ID to committed coordinates.
pub const ReviewLocation = struct {
    location_id: LocationId,
    path_bytes: []const u8,
    side: anchor.AnchorSide,
    line: u32,
};

/// One exact-head advisory `AGENTS.md` source and its unchanged content.
pub const Guidance = struct {
    head_oid: []const u8,
    path_bytes: []const u8,
    blob_oid: []const u8,
    content_digest: identity.Sha256Digest,
    content: []const u8,
};

/// Half-open byte coverage in the exact projection payload.
pub const CoverageSpan = struct {
    start: u32,
    end_exclusive: u32,
};

pub const ReviewUnit = struct {
    schema_version: u64,
    plan_digest: identity.Sha256Digest,
    unit_id: UnitId,
    ordinal: u16,
    unit_count: u16,
    old_path_bytes: ?[]const u8,
    new_path_bytes: ?[]const u8,
    display_path: []const u8,
    file_status: FileStatus,
    metadata_lines: []const []const u8,
    hunks: []const ReviewHunk,
    before_guidance: []const Guidance,
    after_guidance: []const Guidance,
    coverage_spans: []const CoverageSpan,

    pub fn parseStrict(allocator: std.mem.Allocator, bytes: []const u8) @import("codec.zig").ParseError!@import("codec.zig").Parsed(ReviewUnit) {
        return @import("codec.zig").parseReviewUnit(allocator, bytes);
    }

    pub fn writeCanonical(self: *const ReviewUnit, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writeReviewUnitAlloc(allocator, self);
    }
};

/// One derived location and the exact diff line that owns its opaque ID. All
/// slices borrow storage from the Review Unit passed to the iterator.
pub const ReviewLocationOccurrence = struct {
    location: ReviewLocation,
    diff_line: *const DiffLine,
};

pub const ReviewLocationError = error{ InvalidMapping, LimitExceeded };

const SourcePosition = struct {
    line: u64,
    after_line: bool,
};

const SourceSpan = struct {
    first: SourcePosition,
    last: SourcePosition,
};

fn sourceSpan(start: u32, count: u32) SourceSpan {
    if (count == 0) {
        const position: SourcePosition = .{ .line = start, .after_line = true };
        return .{ .first = position, .last = position };
    }
    return .{
        .first = .{ .line = start, .after_line = false },
        .last = .{ .line = @as(u64, start) + count - 1, .after_line = false },
    };
}

fn sourcePositionBefore(left: SourcePosition, right: SourcePosition) bool {
    if (left.line != right.line) return left.line < right.line;
    return !left.after_line and right.after_line;
}

/// The sole unit-local mapping from ordered hunk lines and opaque IDs to
/// committed coordinates. Each Review Unit restarts both side ordinals at 1.
pub const ReviewLocationIterator = struct {
    unit: *const ReviewUnit,
    hunk_index: usize = 0,
    line_index: usize = 0,
    hunk_initialized: bool = false,
    old_line: u64 = 0,
    new_line: u64 = 0,
    old_used: u64 = 0,
    new_used: u64 = 0,
    next_before: usize = 1,
    next_after: usize = 1,
    total_lines: usize = 0,
    previous_old_end: ?SourcePosition = null,
    previous_new_end: ?SourcePosition = null,
    old_ended_without_lf: bool = false,
    new_ended_without_lf: bool = false,
    pending_after: ?ReviewLocationOccurrence = null,

    pub fn init(unit: *const ReviewUnit) ReviewLocationIterator {
        return .{ .unit = unit };
    }

    pub fn next(self: *ReviewLocationIterator) ReviewLocationError!?ReviewLocationOccurrence {
        if (self.pending_after) |occurrence| {
            self.pending_after = null;
            return occurrence;
        }

        while (self.hunk_index < self.unit.hunks.len) {
            const hunk = &self.unit.hunks[self.hunk_index];
            if (!self.hunk_initialized) try self.beginHunk(hunk);
            if (self.line_index == hunk.lines.len) {
                if (self.old_used != hunk.old_count or self.new_used != hunk.new_count) {
                    return error.InvalidMapping;
                }
                self.hunk_index += 1;
                self.line_index = 0;
                self.hunk_initialized = false;
                continue;
            }

            const line = &hunk.lines[self.line_index];
            self.line_index += 1;
            const consumes_old = line.kind != .added;
            const consumes_new = line.kind != .removed;
            if ((consumes_old and self.old_ended_without_lf) or
                (consumes_new and self.new_ended_without_lf))
            {
                return error.InvalidMapping;
            }

            const occurrence = switch (line.kind) {
                .context => context: {
                    const before = try self.derive(line, line.before_location, .before, self.old_line);
                    const after = try self.derive(line, line.after_location, .after, self.new_line);
                    self.pending_after = after;
                    break :context before;
                },
                .removed => removed: {
                    if (line.after_location != null) return error.InvalidMapping;
                    break :removed try self.derive(line, line.before_location, .before, self.old_line);
                },
                .added => added: {
                    if (line.before_location != null) return error.InvalidMapping;
                    break :added try self.derive(line, line.after_location, .after, self.new_line);
                },
            };

            if (consumes_old) {
                self.old_line += 1;
                self.old_used += 1;
            }
            if (consumes_new) {
                self.new_line += 1;
                self.new_used += 1;
            }
            if (line.line_ending == .none) {
                if (consumes_old) self.old_ended_without_lf = true;
                if (consumes_new) self.new_ended_without_lf = true;
            }
            return occurrence;
        }
        return null;
    }

    fn beginHunk(self: *ReviewLocationIterator, hunk: *const ReviewHunk) ReviewLocationError!void {
        if ((hunk.old_count > 0 and hunk.old_start == 0) or
            (hunk.new_count > 0 and hunk.new_start == 0) or hunk.lines.len == 0)
        {
            return error.InvalidMapping;
        }
        const old_span = sourceSpan(hunk.old_start, hunk.old_count);
        const new_span = sourceSpan(hunk.new_start, hunk.new_count);
        if (self.previous_old_end) |previous| {
            if (!sourcePositionBefore(previous, old_span.first)) return error.InvalidMapping;
        }
        if (self.previous_new_end) |previous| {
            if (!sourcePositionBefore(previous, new_span.first)) return error.InvalidMapping;
        }
        self.previous_old_end = old_span.last;
        self.previous_new_end = new_span.last;
        self.total_lines = std.math.add(usize, self.total_lines, hunk.lines.len) catch
            return error.LimitExceeded;
        if (self.total_lines > limits.max_lines_per_unit) return error.LimitExceeded;
        self.old_line = hunk.old_start;
        self.new_line = hunk.new_start;
        self.old_used = 0;
        self.new_used = 0;
        self.hunk_initialized = true;
    }

    fn derive(
        self: *ReviewLocationIterator,
        diff_line: *const DiffLine,
        optional_id: ?LocationId,
        side: anchor.AnchorSide,
        committed_line: u64,
    ) ReviewLocationError!ReviewLocationOccurrence {
        const id = optional_id orelse return error.InvalidMapping;
        const expected = switch (side) {
            .before => &self.next_before,
            .after => &self.next_after,
        };
        if (expected.* > limits.max_locations_per_side) return error.LimitExceeded;
        if (id.side != side or id.ordinal != expected.*) return error.InvalidMapping;
        const path = switch (side) {
            .before => self.unit.old_path_bytes,
            .after => self.unit.new_path_bytes,
        } orelse return error.InvalidMapping;
        if (committed_line == 0 or committed_line > std.math.maxInt(u32)) return error.InvalidMapping;
        expected.* += 1;
        return .{
            .location = .{
                .location_id = id,
                .path_bytes = path,
                .side = side,
                .line = @intCast(committed_line),
            },
            .diff_line = diff_line,
        };
    }
};

/// Resolve one opaque ID while also validating the complete unit-local mapping.
pub fn findReviewLocation(
    unit: *const ReviewUnit,
    id: LocationId,
) ReviewLocationError!?ReviewLocationOccurrence {
    var iterator = ReviewLocationIterator.init(unit);
    var found: ?ReviewLocationOccurrence = null;
    while (try iterator.next()) |occurrence| {
        if (!occurrence.location.location_id.eql(id)) continue;
        if (found != null) return error.InvalidMapping;
        found = occurrence;
    }
    return found;
}

/// The complete and only AI-authored finding value.
pub const FindingCandidate = struct {
    start_location: LocationId,
    end_location: LocationId,
    severity: artifact.Severity,
    title: []const u8,
    body: []const u8,
    suggestion: ?[]const u8 = null,
};

pub const FindingCandidatePayload = struct {
    findings: []const FindingCandidate,

    pub fn parseStrict(allocator: std.mem.Allocator, bytes: []const u8) @import("codec.zig").ParseError!@import("codec.zig").Parsed(FindingCandidatePayload) {
        return @import("codec.zig").parseCandidatePayload(allocator, bytes);
    }

    pub fn writeCanonical(self: *const FindingCandidatePayload, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writeCandidatePayloadAlloc(allocator, self);
    }
};

pub const CandidateBatchStatus = enum { reviewed };

/// Deterministic helper envelope around one AI-authored unit payload.
pub const FindingCandidateBatch = struct {
    schema_version: u64,
    plan_digest: identity.Sha256Digest,
    unit_id: UnitId,
    status: CandidateBatchStatus,
    findings: []const FindingCandidate,

    pub fn parseStrict(allocator: std.mem.Allocator, bytes: []const u8) @import("codec.zig").ParseError!@import("codec.zig").Parsed(FindingCandidateBatch) {
        return @import("codec.zig").parseCandidateBatch(allocator, bytes);
    }

    pub fn writeCanonical(self: *const FindingCandidateBatch, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writeCandidateBatchAlloc(allocator, self);
    }
};

pub const Capability = struct {
    name: []const u8,
    versions: []const u16,
};

pub const CapabilityResponse = struct {
    schema_version: u64,
    status: enum { ok },
    gitframe_version: []const u8,
    capabilities: []const Capability,

    pub fn parseStrict(allocator: std.mem.Allocator, bytes: []const u8) @import("codec.zig").ParseError!@import("codec.zig").Parsed(CapabilityResponse) {
        return @import("codec.zig").parseCapabilityResponse(allocator, bytes);
    }

    pub fn writeCanonical(self: *const CapabilityResponse, allocator: std.mem.Allocator) @import("codec.zig").ParseError![]u8 {
        return @import("codec.zig").writeCapabilityResponseAlloc(allocator, self);
    }
};

pub const CapabilityRequirement = struct {
    name: []const u8,
    version: u16,
};

pub const CapabilityCompatibilityError = error{IncompatibleCapabilities};

/// Require exact name/version membership; semver and future-only versions do
/// not authorize an operation.
pub fn requireCapabilities(
    response: *const CapabilityResponse,
    requirements: []const CapabilityRequirement,
) CapabilityCompatibilityError!void {
    for (requirements) |requirement| {
        var found = false;
        for (response.capabilities) |capability| {
            if (!std.mem.eql(u8, capability.name, requirement.name)) continue;
            for (capability.versions) |version| {
                if (version == requirement.version) found = true;
            }
            break;
        }
        if (!found) return error.IncompatibleCapabilities;
    }
}

fn fixedDecimal(comptime T: type, bytes: []const u8) !T {
    for (bytes) |byte| if (byte < '0' or byte > '9') return error.InvalidDecimal;
    return std.fmt.parseInt(T, bytes, 10);
}

fn writeFourDigits(destination: []u8, value: u16) void {
    std.debug.assert(destination.len == 4 and value <= 9999);
    destination[0] = @intCast('0' + (value / 1000) % 10);
    destination[1] = @intCast('0' + (value / 100) % 10);
    destination[2] = @intCast('0' + (value / 10) % 10);
    destination[3] = @intCast('0' + value % 10);
}

test "AI review protocol IDs have one bounded canonical spelling" {
    const unit = try UnitId.parse("unit-0256");
    try std.testing.expectEqual(@as(u16, 256), unit.ordinal);
    try std.testing.expectEqualStrings("unit-0256", &unit.canonical());
    try std.testing.expectError(error.InvalidUnitId, UnitId.parse("unit-0257"));
    try std.testing.expectError(error.InvalidUnitId, UnitId.parse("unit-1"));

    const before = try LocationId.parse("b9999");
    try std.testing.expectEqual(anchor.AnchorSide.before, before.side);
    try std.testing.expectEqualStrings("b9999", &before.canonical());
    try std.testing.expectError(error.InvalidLocationId, LocationId.parse("b0000"));
    try std.testing.expectError(error.InvalidLocationId, LocationId.parse("x0001"));
}

test "AI review protocol capability admission uses exact version membership" {
    const versions = [_]u16{2};
    const response: CapabilityResponse = .{
        .schema_version = 1,
        .status = .ok,
        .gitframe_version = "0.0.0",
        .capabilities = &.{.{ .name = "ai-review.input", .versions = &versions }},
    };
    try requireCapabilities(&response, &.{.{ .name = "ai-review.input", .version = 2 }});
    try std.testing.expectError(
        error.IncompatibleCapabilities,
        requireCapabilities(&response, &.{.{ .name = "ai-review.input", .version = 1 }}),
    );
    try std.testing.expectError(
        error.IncompatibleCapabilities,
        requireCapabilities(&response, &.{.{ .name = "committed-review.target", .version = 1 }}),
    );
}
