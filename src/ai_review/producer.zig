//! Provider-neutral construction of immutable AI review artifacts.
//!
//! This module owns deterministic candidate admission and artifact bytes. Git
//! access is represented by one narrow verifier port; Store and filesystem IO
//! belong to command adapters outside this domain boundary.

const std = @import("std");
const committed = @import("../committed_review.zig");
const codec = @import("codec.zig");
const limits = @import("limits.zig");
const protocol = @import("protocol.zig");

pub const BuildError = error{
    OutOfMemory,
    InvalidInput,
    IncompleteCandidateCoverage,
    CandidateLimitExceeded,
    InvalidCandidateLocation,
    AnchorUnavailable,
    InvalidArtifact,
};

pub const VerifyError = error{ OutOfMemory, AnchorUnavailable };

/// Read-only authority used to prove a derived anchor against committed bytes.
pub const AnchorVerifier = struct {
    context: ?*anyopaque = null,
    verify_fn: *const fn (
        context: ?*anyopaque,
        target: *const committed.CommittedReviewTarget,
        anchor: committed.CodeAnchor,
    ) VerifyError!void,

    pub fn verify(
        self: AnchorVerifier,
        target: *const committed.CommittedReviewTarget,
        anchor: committed.CodeAnchor,
    ) VerifyError!void {
        return self.verify_fn(self.context, target, anchor);
    }
};

/// All values are already strict-parsed; the builder revalidates their value
/// invariants before using any borrowed field as artifact authority.
pub const Input = struct {
    summary: *const protocol.ReviewPlanSummary,
    units: []const protocol.ReviewUnit,
    candidates: []const protocol.FindingCandidatePayload,
    review_repository_id: committed.ReviewRepositoryId,
    review_id: committed.ReviewId,
    producer: committed.Producer,
    created_at: []const u8,
    display: ?committed.DisplayMetadata = null,
};

/// Exact canonical bytes returned to the publication adapter.
pub const ArtifactBundle = struct {
    manifest_bytes: []u8,
    findings_bytes: []u8,
    manifest_digest: committed.Sha256Digest,
    findings_digest: committed.Sha256Digest,
    finding_count: u32,

    pub fn deinit(self: *ArtifactBundle, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_bytes);
        allocator.free(self.findings_bytes);
        self.* = undefined;
    }
};

const ResolvedCandidate = struct {
    anchor: committed.CodeAnchor,
    severity: committed.Severity,
    title: []const u8,
    body: []const u8,
    suggestion: ?[]const u8,
};

/// Build one complete FindingSet/manifest pair without publishing it.
pub fn buildAlloc(
    allocator: std.mem.Allocator,
    input: Input,
    verifier: AnchorVerifier,
) BuildError!ArtifactBundle {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try validateCompleteInput(allocator, input);

    var resolved: std.ArrayList(ResolvedCandidate) = .empty;
    var candidate_bytes: usize = 0;
    for (input.units, input.candidates) |*unit, *payload| {
        const canonical = payload.writeCanonical(allocator) catch |err| return mapCandidateError(err);
        defer allocator.free(canonical);
        candidate_bytes = std.math.add(usize, candidate_bytes, canonical.len) catch
            return error.CandidateLimitExceeded;
        if (candidate_bytes > limits.max_candidate_batches_bytes) return error.CandidateLimitExceeded;
        if (resolved.items.len + payload.findings.len > limits.max_findings_total) {
            return error.CandidateLimitExceeded;
        }

        for (payload.findings) |candidate| {
            const item = try resolveCandidate(unit, candidate);
            verifier.verify(&input.summary.target, item.anchor) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.AnchorUnavailable => error.AnchorUnavailable,
            };
            resolved.append(arena, item) catch return error.OutOfMemory;
        }
    }

    std.mem.sort(ResolvedCandidate, resolved.items, {}, resolvedLessThan);
    const unique_count = deduplicateSorted(resolved.items);
    const findings = arena.alloc(committed.Finding, unique_count) catch return error.OutOfMemory;
    for (resolved.items[0..unique_count], findings, 0..) |candidate, *finding, index| {
        const finding_id = std.fmt.allocPrint(arena, "finding-{d:0>4}", .{index + 1}) catch
            return error.OutOfMemory;
        finding.* = .{
            .finding_id = .{ .bytes = finding_id },
            .anchor = candidate.anchor,
            .severity = candidate.severity,
            .title = candidate.title,
            .body = candidate.body,
            .suggestion = candidate.suggestion,
        };
    }

    const finding_set: committed.FindingSet = .{
        .schema_version = 1,
        .review_id = input.review_id,
        .created_at = input.created_at,
        .timing = null,
        .target = input.summary.target,
        .producer = input.producer,
        .findings = findings,
    };
    const findings_bytes = finding_set.writeCanonical(allocator) catch |err|
        return mapArtifactError(err);
    errdefer allocator.free(findings_bytes);
    const findings_digest = committed.Sha256Digest.hash(findings_bytes);

    const manifest: committed.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = input.review_id,
        .review_repository_id = input.review_repository_id,
        .target = input.summary.target,
        .created_at = input.created_at,
        .display = input.display,
        .finding_count = @intCast(findings.len),
        .producer = input.producer,
        .findings_digest = findings_digest,
    };
    const manifest_bytes = manifest.writeCanonical(allocator) catch |err|
        return mapArtifactError(err);
    errdefer allocator.free(manifest_bytes);

    try validateArtifacts(arena, manifest_bytes, findings_bytes);
    return .{
        .manifest_bytes = manifest_bytes,
        .findings_bytes = findings_bytes,
        .manifest_digest = committed.Sha256Digest.hash(manifest_bytes),
        .findings_digest = findings_digest,
        .finding_count = @intCast(findings.len),
    };
}

fn validateCompleteInput(allocator: std.mem.Allocator, input: Input) BuildError!void {
    const summary_bytes = input.summary.writeCanonical(allocator) catch |err|
        return mapInputError(err);
    defer allocator.free(summary_bytes);
    if (input.summary.unit_count == 0 or
        input.units.len != input.summary.unit_count or
        input.candidates.len != input.summary.unit_count)
    {
        return error.IncompleteCandidateCoverage;
    }

    for (input.units, 0..) |*unit, index| {
        const unit_bytes = unit.writeCanonical(allocator) catch |err|
            return mapInputError(err);
        defer allocator.free(unit_bytes);
        const ordinal: u16 = @intCast(index + 1);
        if (unit.schema_version != input.summary.schema_version or
            !unit.plan_digest.eql(input.summary.plan_digest) or
            unit.unit_count != input.summary.unit_count or
            unit.ordinal != ordinal or
            unit.unit_id.ordinal != ordinal)
        {
            return error.IncompleteCandidateCoverage;
        }
    }

    const actual_digest = try computePlanDigest(allocator, input.summary, input.units);
    if (!actual_digest.eql(input.summary.plan_digest)) return error.IncompleteCandidateCoverage;
}

fn computePlanDigest(
    allocator: std.mem.Allocator,
    summary: *const protocol.ReviewPlanSummary,
    units: []const protocol.ReviewUnit,
) BuildError!committed.Sha256Digest {
    const zero_digest: committed.Sha256Digest = .{ .bytes = [_]u8{0} ** 32 };
    var zeroed_summary = summary.*;
    zeroed_summary.plan_digest = zero_digest;
    const summary_bytes = zeroed_summary.writeCanonical(allocator) catch |err|
        return mapInputError(err);
    defer allocator.free(summary_bytes);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("gitframe-ai-review-plan-v1\x00");
    hasher.update(summary_bytes);
    for (units) |unit| {
        var zeroed_unit = unit;
        zeroed_unit.plan_digest = zero_digest;
        const unit_bytes = zeroed_unit.writeCanonical(allocator) catch |err|
            return mapInputError(err);
        defer allocator.free(unit_bytes);
        hasher.update(unit_bytes);
    }
    var digest: committed.Sha256Digest = undefined;
    hasher.final(&digest.bytes);
    return digest;
}

fn resolveCandidate(
    unit: *const protocol.ReviewUnit,
    candidate: protocol.FindingCandidate,
) BuildError!ResolvedCandidate {
    const start = findLocation(unit, candidate.start_location) orelse
        return error.InvalidCandidateLocation;
    const end = findLocation(unit, candidate.end_location) orelse
        return error.InvalidCandidateLocation;
    if (start.side != end.side or
        !std.mem.eql(u8, start.path_bytes, end.path_bytes) or
        end.line < start.line)
    {
        return error.InvalidCandidateLocation;
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const count = @as(usize, candidate.end_location.ordinal) -
        @as(usize, candidate.start_location.ordinal) + 1;
    if (@as(u64, start.line) + @as(u64, @intCast(count)) - 1 != end.line) {
        return error.InvalidCandidateLocation;
    }
    for (0..count) |offset| {
        const ordinal = @as(u16, candidate.start_location.ordinal) + @as(u16, @intCast(offset));
        const location_id: protocol.LocationId = .{ .side = start.side, .ordinal = ordinal };
        const location = findLocation(unit, location_id) orelse return error.InvalidCandidateLocation;
        if (location.line != @as(u64, start.line) + offset or
            !std.mem.eql(u8, start.path_bytes, location.path_bytes))
        {
            return error.InvalidCandidateLocation;
        }
        const line = findDiffLine(unit, location_id) orelse return error.InvalidCandidateLocation;
        hasher.update(line.text);
        hasher.update(switch (line.line_ending) {
            .lf => "\n",
            .crlf => "\r\n",
            .none => "",
        });
    }

    var content_digest: committed.Sha256Digest = undefined;
    hasher.final(&content_digest.bytes);

    return .{
        .anchor = .{
            .path_bytes = start.path_bytes,
            .display_path = unit.display_path,
            .side = start.side,
            .start_line = start.line,
            .end_line = end.line,
            .content_digest = content_digest,
            .quoted_text = null,
        },
        .severity = candidate.severity,
        .title = candidate.title,
        .body = candidate.body,
        .suggestion = candidate.suggestion,
    };
}

fn findLocation(unit: *const protocol.ReviewUnit, id: protocol.LocationId) ?protocol.ReviewLocation {
    for (unit.locations) |location| if (location.location_id.eql(id)) return location;
    return null;
}

fn findDiffLine(unit: *const protocol.ReviewUnit, id: protocol.LocationId) ?protocol.DiffLine {
    for (unit.hunks) |hunk| {
        for (hunk.lines) |line| {
            const actual = switch (id.side) {
                .before => line.before_location,
                .after => line.after_location,
            };
            if (actual) |location_id| if (location_id.eql(id)) return line;
        }
    }
    return null;
}

fn resolvedLessThan(_: void, left: ResolvedCandidate, right: ResolvedCandidate) bool {
    return compareResolved(left, right) == .lt;
}

fn compareResolved(left: ResolvedCandidate, right: ResolvedCandidate) std.math.Order {
    var order = std.mem.order(u8, left.anchor.path_bytes, right.anchor.path_bytes);
    if (order != .eq) return order;
    order = compareEnum(left.anchor.side, right.anchor.side);
    if (order != .eq) return order;
    order = std.math.order(left.anchor.start_line, right.anchor.start_line);
    if (order != .eq) return order;
    order = std.math.order(left.anchor.end_line, right.anchor.end_line);
    if (order != .eq) return order;
    order = compareEnum(left.severity, right.severity);
    if (order != .eq) return order;
    order = std.mem.order(u8, left.title, right.title);
    if (order != .eq) return order;
    order = std.mem.order(u8, left.body, right.body);
    if (order != .eq) return order;
    if (left.suggestion == null or right.suggestion == null) {
        if (left.suggestion == null and right.suggestion == null) return .eq;
        return if (left.suggestion == null) .lt else .gt;
    }
    return std.mem.order(u8, left.suggestion.?, right.suggestion.?);
}

fn compareEnum(left: anytype, right: @TypeOf(left)) std.math.Order {
    return std.math.order(@intFromEnum(left), @intFromEnum(right));
}

fn deduplicateSorted(items: []ResolvedCandidate) usize {
    if (items.len == 0) return 0;
    var write_index: usize = 1;
    for (items[1..]) |item| {
        if (compareResolved(items[write_index - 1], item) == .eq) continue;
        items[write_index] = item;
        write_index += 1;
    }
    return write_index;
}

fn validateArtifacts(
    allocator: std.mem.Allocator,
    manifest_bytes: []const u8,
    findings_bytes: []const u8,
) BuildError!void {
    var findings = committed.FindingSet.parseStrict(allocator, findings_bytes) catch |err|
        return mapArtifactError(err);
    defer findings.deinit();
    var manifest = committed.ReviewRunManifest.parseStrict(allocator, manifest_bytes) catch |err|
        return mapArtifactError(err);
    defer manifest.deinit();
    manifest.value.validateFindingSet(findings_bytes, &findings.value) catch
        return error.InvalidArtifact;
}

fn mapInputError(err: anyerror) BuildError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidInput;
}

fn mapCandidateError(err: anyerror) BuildError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LimitExceeded, error.ArtifactTooLarge => error.CandidateLimitExceeded,
        else => error.InvalidInput,
    };
}

fn mapArtifactError(err: anyerror) BuildError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidArtifact;
}

const TestFixture = struct {
    allocator: std.mem.Allocator,
    summary_bytes: []u8,
    unit_bytes: []u8,
    candidate_bytes: []u8,
    summary: codec.Parsed(protocol.ReviewPlanSummary),
    unit: codec.Parsed(protocol.ReviewUnit),
    candidate: codec.Parsed(protocol.FindingCandidatePayload),

    fn init(allocator: std.mem.Allocator) !TestFixture {
        const summary_bytes = try readFixture(allocator, "testdata/ai-review-producer-v1/protocol/plan.json");
        errdefer allocator.free(summary_bytes);
        const unit_bytes = try readFixture(allocator, "testdata/ai-review-producer-v1/protocol/unit.json");
        errdefer allocator.free(unit_bytes);
        const candidate_bytes = try readFixture(allocator, "testdata/ai-review-producer-v1/protocol/candidate.json");
        errdefer allocator.free(candidate_bytes);
        var summary = try protocol.ReviewPlanSummary.parseStrict(allocator, summary_bytes);
        errdefer summary.deinit();
        var unit = try protocol.ReviewUnit.parseStrict(allocator, unit_bytes);
        errdefer unit.deinit();
        var candidate = try protocol.FindingCandidatePayload.parseStrict(allocator, candidate_bytes);
        errdefer candidate.deinit();
        const units = [_]protocol.ReviewUnit{unit.value};
        const plan_digest = try computePlanDigest(allocator, &summary.value, &units);
        summary.value.plan_digest = plan_digest;
        unit.value.plan_digest = plan_digest;
        return .{
            .allocator = allocator,
            .summary_bytes = summary_bytes,
            .unit_bytes = unit_bytes,
            .candidate_bytes = candidate_bytes,
            .summary = summary,
            .unit = unit,
            .candidate = candidate,
        };
    }

    fn deinit(self: *TestFixture) void {
        self.candidate.deinit();
        self.unit.deinit();
        self.summary.deinit();
        self.allocator.free(self.candidate_bytes);
        self.allocator.free(self.unit_bytes);
        self.allocator.free(self.summary_bytes);
        self.* = undefined;
    }
};

const RecordingVerifier = struct {
    calls: [64]committed.CodeAnchor = undefined,
    count: usize = 0,
    target: ?committed.CommittedReviewTarget = null,
    fail_at: ?usize = null,

    fn port(self: *RecordingVerifier) AnchorVerifier {
        return .{ .context = self, .verify_fn = verify };
    }

    fn verify(
        context: ?*anyopaque,
        target: *const committed.CommittedReviewTarget,
        anchor: committed.CodeAnchor,
    ) VerifyError!void {
        const self: *RecordingVerifier = @ptrCast(@alignCast(context.?));
        if (self.fail_at != null and self.fail_at.? == self.count) return error.AnchorUnavailable;
        self.target = target.*;
        self.calls[self.count] = anchor;
        self.count += 1;
    }
};

fn acceptAnchor(
    _: ?*anyopaque,
    _: *const committed.CommittedReviewTarget,
    _: committed.CodeAnchor,
) VerifyError!void {}

fn testInput(
    fixture: *const TestFixture,
    summary: *const protocol.ReviewPlanSummary,
    units: []const protocol.ReviewUnit,
    candidates: []const protocol.FindingCandidatePayload,
) !Input {
    _ = fixture;
    return .{
        .summary = summary,
        .units = units,
        .candidates = candidates,
        .review_repository_id = try committed.ReviewRepositoryId.parse("123e4567-e89b-42d3-b456-426614174000"),
        .review_id = try committed.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000"),
        .producer = .{ .name = "codex", .model = "gpt-5", .version = "1" },
        .created_at = "2026-08-26T13:00:00Z",
        .display = .{ .base_label = "main", .head_label = "feature" },
    };
}

fn bindTestPlan(
    allocator: std.mem.Allocator,
    summary: *protocol.ReviewPlanSummary,
    units: []protocol.ReviewUnit,
) !void {
    const digest = try computePlanDigest(allocator, summary, units);
    summary.plan_digest = digest;
    for (units) |*unit| unit.plan_digest = digest;
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
}

test "AI review producer domain builds and validates exact canonical artifacts" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    const units = [_]protocol.ReviewUnit{fixture.unit.value};
    const candidates = [_]protocol.FindingCandidatePayload{fixture.candidate.value};
    const input = try testInput(&fixture, &fixture.summary.value, &units, &candidates);
    var verifier: RecordingVerifier = .{};

    var bundle = try buildAlloc(allocator, input, verifier.port());
    defer bundle.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), bundle.finding_count);
    try std.testing.expect(bundle.manifest_digest.eql(committed.Sha256Digest.hash(bundle.manifest_bytes)));
    try std.testing.expect(bundle.findings_digest.eql(committed.Sha256Digest.hash(bundle.findings_bytes)));
    try std.testing.expectEqual(@as(usize, 1), verifier.count);
    try std.testing.expect(input.summary.target.eql(&verifier.target.?));
    try std.testing.expectEqualStrings("src/main.zig", verifier.calls[0].path_bytes);
    try std.testing.expectEqual(committed.AnchorSide.after, verifier.calls[0].side);
    try std.testing.expectEqual(@as(u32, 2), verifier.calls[0].start_line);
    try std.testing.expectEqual(@as(u32, 2), verifier.calls[0].end_line);
    try std.testing.expect(verifier.calls[0].content_digest.eql(committed.Sha256Digest.hash("new();\r\n")));

    var findings = try committed.FindingSet.parseStrict(allocator, bundle.findings_bytes);
    defer findings.deinit();
    var manifest = try committed.ReviewRunManifest.parseStrict(allocator, bundle.manifest_bytes);
    defer manifest.deinit();
    try manifest.value.validateFindingSet(bundle.findings_bytes, &findings.value);
    try std.testing.expect(findings.value.timing == null);
    try std.testing.expectEqualStrings("finding-0001", findings.value.findings[0].finding_id.bytes);
}

test "AI review producer domain emits an empty complete FindingSet" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    const units = [_]protocol.ReviewUnit{fixture.unit.value};
    const candidates = [_]protocol.FindingCandidatePayload{.{ .findings = &.{} }};
    const input = try testInput(&fixture, &fixture.summary.value, &units, &candidates);
    var verifier: RecordingVerifier = .{};
    var bundle = try buildAlloc(allocator, input, verifier.port());
    defer bundle.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), bundle.finding_count);
    try std.testing.expectEqual(@as(usize, 0), verifier.count);
    var findings = try committed.FindingSet.parseStrict(allocator, bundle.findings_bytes);
    defer findings.deinit();
    try std.testing.expectEqual(@as(usize, 0), findings.value.findings.len);
}

test "AI review producer domain rejects incomplete and duplicate unit coverage" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    var summary = fixture.summary.value;
    summary.unit_count = 2;
    const duplicate_units = [_]protocol.ReviewUnit{ fixture.unit.value, fixture.unit.value };
    const one_candidate = [_]protocol.FindingCandidatePayload{fixture.candidate.value};
    const two_candidates = [_]protocol.FindingCandidatePayload{ fixture.candidate.value, fixture.candidate.value };
    var verifier: RecordingVerifier = .{};
    try std.testing.expectError(
        error.IncompleteCandidateCoverage,
        buildAlloc(allocator, try testInput(&fixture, &summary, duplicate_units[0..1], &one_candidate), verifier.port()),
    );
    try std.testing.expectError(
        error.IncompleteCandidateCoverage,
        buildAlloc(allocator, try testInput(&fixture, &summary, &duplicate_units, &two_candidates), verifier.port()),
    );
}

test "AI review producer domain rejects zero-unit completion" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    var summary = fixture.summary.value;
    summary.unit_count = 0;
    var verifier: RecordingVerifier = .{};
    try std.testing.expectError(
        error.IncompleteCandidateCoverage,
        buildAlloc(
            allocator,
            try testInput(&fixture, &summary, &.{}, &.{}),
            verifier.port(),
        ),
    );
}

test "AI review producer domain rejects a mismatched plan digest" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    var unit = fixture.unit.value;
    unit.plan_digest = committed.Sha256Digest.hash("another plan");
    const units = [_]protocol.ReviewUnit{unit};
    const candidates = [_]protocol.FindingCandidatePayload{fixture.candidate.value};
    var verifier: RecordingVerifier = .{};
    try std.testing.expectError(
        error.IncompleteCandidateCoverage,
        buildAlloc(
            allocator,
            try testInput(&fixture, &fixture.summary.value, &units, &candidates),
            verifier.port(),
        ),
    );
}

test "AI review producer domain rejects authority mutations under an unchanged plan digest" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    const empty_candidates = [_]protocol.FindingCandidatePayload{.{ .findings = &.{} }};
    var verifier: RecordingVerifier = .{};

    var summary = fixture.summary.value;
    summary.target.head_oid = try committed.ObjectId.parse(
        .sha1,
        "2222222222222222222222222222222222222222",
    );
    const original_unit = [_]protocol.ReviewUnit{fixture.unit.value};
    try std.testing.expectError(
        error.IncompleteCandidateCoverage,
        buildAlloc(
            allocator,
            try testInput(&fixture, &summary, &original_unit, &empty_candidates),
            verifier.port(),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), verifier.count);

    var unit = fixture.unit.value;
    const changed_metadata = [_][]const u8{"index 2222222..1111111 100644"};
    unit.metadata_lines = &changed_metadata;
    const changed_unit = [_]protocol.ReviewUnit{unit};
    try std.testing.expectError(
        error.IncompleteCandidateCoverage,
        buildAlloc(
            allocator,
            try testInput(&fixture, &fixture.summary.value, &changed_unit, &empty_candidates),
            verifier.port(),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), verifier.count);
}

test "AI review producer domain preserves final-no-LF anchor bytes" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    var lines = [_]protocol.DiffLine{
        fixture.unit.value.hunks[0].lines[0],
        fixture.unit.value.hunks[0].lines[1],
        fixture.unit.value.hunks[0].lines[2],
    };
    lines[2].line_ending = .none;
    var hunks = [_]protocol.ReviewHunk{fixture.unit.value.hunks[0]};
    hunks[0].lines = &lines;
    var unit = fixture.unit.value;
    unit.hunks = &hunks;
    var summary = fixture.summary.value;
    var units = [_]protocol.ReviewUnit{unit};
    try bindTestPlan(allocator, &summary, &units);
    const candidates = [_]protocol.FindingCandidatePayload{fixture.candidate.value};
    var verifier: RecordingVerifier = .{};
    var bundle = try buildAlloc(
        allocator,
        try testInput(&fixture, &summary, &units, &candidates),
        verifier.port(),
    );
    defer bundle.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), verifier.count);
    try std.testing.expect(verifier.calls[0].content_digest.eql(committed.Sha256Digest.hash("new();")));
}

test "AI review producer domain propagates committed anchor unavailability" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    const units = [_]protocol.ReviewUnit{fixture.unit.value};
    const candidates = [_]protocol.FindingCandidatePayload{fixture.candidate.value};
    var verifier: RecordingVerifier = .{ .fail_at = 0 };
    try std.testing.expectError(
        error.AnchorUnavailable,
        buildAlloc(
            allocator,
            try testInput(&fixture, &fixture.summary.value, &units, &candidates),
            verifier.port(),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), verifier.count);
}

test "AI review producer domain sorts deduplicates and assigns finding IDs" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    const after_two: protocol.FindingCandidate = .{
        .start_location = .{ .side = .after, .ordinal = 2 },
        .end_location = .{ .side = .after, .ordinal = 2 },
        .severity = .warning,
        .title = "Zulu",
        .body = "same-location warning",
    };
    const before_two: protocol.FindingCandidate = .{
        .start_location = .{ .side = .before, .ordinal = 2 },
        .end_location = .{ .side = .before, .ordinal = 2 },
        .severity = .@"error",
        .title = "Before",
        .body = "before sorts ahead of after",
    };
    const after_one: protocol.FindingCandidate = .{
        .start_location = .{ .side = .after, .ordinal = 1 },
        .end_location = .{ .side = .after, .ordinal = 1 },
        .severity = .info,
        .title = "Earlier",
        .body = "lower line sorts first",
    };
    const after_two_info: protocol.FindingCandidate = .{
        .start_location = .{ .side = .after, .ordinal = 2 },
        .end_location = .{ .side = .after, .ordinal = 2 },
        .severity = .info,
        .title = "Alpha",
        .body = "same body",
    };
    var after_two_suggestion = after_two_info;
    after_two_suggestion.suggestion = "replacement";
    const findings = [_]protocol.FindingCandidate{
        after_two,
        after_two_suggestion,
        before_two,
        after_one,
        after_two_info,
        after_two,
    };
    const units = [_]protocol.ReviewUnit{fixture.unit.value};
    const candidates = [_]protocol.FindingCandidatePayload{.{ .findings = &findings }};
    var verifier: RecordingVerifier = .{};
    var bundle = try buildAlloc(
        allocator,
        try testInput(&fixture, &fixture.summary.value, &units, &candidates),
        verifier.port(),
    );
    defer bundle.deinit(allocator);
    try std.testing.expectEqual(@as(usize, findings.len), verifier.count);
    try std.testing.expectEqual(@as(u32, 5), bundle.finding_count);

    var parsed = try committed.FindingSet.parseStrict(allocator, bundle.findings_bytes);
    defer parsed.deinit();
    const expected_titles = [_][]const u8{ "Before", "Earlier", "Alpha", "Alpha", "Zulu" };
    for (parsed.value.findings, expected_titles, 0..) |finding, title, index| {
        var expected_id: [12]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&expected_id, "finding-{d:0>4}", .{index + 1});
        try std.testing.expectEqualStrings(rendered, finding.finding_id.bytes);
        try std.testing.expectEqualStrings(title, finding.title);
    }
    try std.testing.expectEqual(committed.AnchorSide.before, parsed.value.findings[0].anchor.side);
    try std.testing.expect(parsed.value.findings[2].suggestion == null);
    try std.testing.expectEqualStrings("replacement", parsed.value.findings[3].suggestion.?);
}

test "AI review producer domain orders findings by unsigned raw path across units" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    var summary = fixture.summary.value;
    summary.unit_count = 2;

    var z_locations = [_]protocol.ReviewLocation{
        fixture.unit.value.locations[0],
        fixture.unit.value.locations[1],
        fixture.unit.value.locations[2],
        fixture.unit.value.locations[3],
    };
    for (&z_locations) |*location| location.path_bytes = "z.zig";
    var z_unit = fixture.unit.value;
    z_unit.unit_count = 2;
    z_unit.old_path_bytes = "z.zig";
    z_unit.new_path_bytes = "z.zig";
    z_unit.display_path = "z.zig";
    z_unit.locations = &z_locations;

    var a_locations = [_]protocol.ReviewLocation{
        fixture.unit.value.locations[0],
        fixture.unit.value.locations[1],
        fixture.unit.value.locations[2],
        fixture.unit.value.locations[3],
    };
    for (&a_locations) |*location| location.path_bytes = "a.zig";
    var a_unit = fixture.unit.value;
    a_unit.unit_id = .{ .ordinal = 2 };
    a_unit.ordinal = 2;
    a_unit.unit_count = 2;
    a_unit.old_path_bytes = "a.zig";
    a_unit.new_path_bytes = "a.zig";
    a_unit.display_path = "a.zig";
    a_unit.locations = &a_locations;

    var units = [_]protocol.ReviewUnit{ z_unit, a_unit };
    try bindTestPlan(allocator, &summary, &units);
    const candidates = [_]protocol.FindingCandidatePayload{ fixture.candidate.value, fixture.candidate.value };
    var verifier: RecordingVerifier = .{};
    var bundle = try buildAlloc(
        allocator,
        try testInput(&fixture, &summary, &units, &candidates),
        verifier.port(),
    );
    defer bundle.deinit(allocator);
    var parsed = try committed.FindingSet.parseStrict(allocator, bundle.findings_bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.findings.len);
    try std.testing.expectEqualStrings("a.zig", parsed.value.findings[0].anchor.path_bytes);
    try std.testing.expectEqualStrings("z.zig", parsed.value.findings[1].anchor.path_bytes);
}

test "AI review producer domain rejects missing and noncontiguous shown locations" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    const missing = [_]protocol.FindingCandidate{.{
        .start_location = .{ .side = .after, .ordinal = 3 },
        .end_location = .{ .side = .after, .ordinal = 3 },
        .severity = .warning,
        .title = "Missing",
        .body = "The location is not present.",
    }};
    const units = [_]protocol.ReviewUnit{fixture.unit.value};
    const missing_payloads = [_]protocol.FindingCandidatePayload{.{ .findings = &missing }};
    var verifier: RecordingVerifier = .{};
    try std.testing.expectError(
        error.InvalidCandidateLocation,
        buildAlloc(
            allocator,
            try testInput(&fixture, &fixture.summary.value, &units, &missing_payloads),
            verifier.port(),
        ),
    );

    const first_line: protocol.DiffLine = .{
        .kind = .context,
        .text = "one",
        .line_ending = .lf,
        .before_location = .{ .side = .before, .ordinal = 1 },
        .after_location = .{ .side = .after, .ordinal = 1 },
    };
    const third_line: protocol.DiffLine = .{
        .kind = .context,
        .text = "three",
        .line_ending = .lf,
        .before_location = .{ .side = .before, .ordinal = 2 },
        .after_location = .{ .side = .after, .ordinal = 2 },
    };
    const first_lines = [_]protocol.DiffLine{first_line};
    const third_lines = [_]protocol.DiffLine{third_line};
    const hunks = [_]protocol.ReviewHunk{
        .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .lines = &first_lines },
        .{ .old_start = 3, .old_count = 1, .new_start = 3, .new_count = 1, .lines = &third_lines },
    };
    const locations = [_]protocol.ReviewLocation{
        .{ .location_id = .{ .side = .before, .ordinal = 1 }, .path_bytes = "src/main.zig", .side = .before, .line = 1 },
        .{ .location_id = .{ .side = .before, .ordinal = 2 }, .path_bytes = "src/main.zig", .side = .before, .line = 3 },
        .{ .location_id = .{ .side = .after, .ordinal = 1 }, .path_bytes = "src/main.zig", .side = .after, .line = 1 },
        .{ .location_id = .{ .side = .after, .ordinal = 2 }, .path_bytes = "src/main.zig", .side = .after, .line = 3 },
    };
    var gapped_unit = fixture.unit.value;
    gapped_unit.hunks = &hunks;
    gapped_unit.locations = &locations;
    var summary = fixture.summary.value;
    var gapped_units = [_]protocol.ReviewUnit{gapped_unit};
    try bindTestPlan(allocator, &summary, &gapped_units);
    const span = [_]protocol.FindingCandidate{.{
        .start_location = .{ .side = .after, .ordinal = 1 },
        .end_location = .{ .side = .after, .ordinal = 2 },
        .severity = .warning,
        .title = "Gap",
        .body = "The shown locations skip committed line two.",
    }};
    const span_payloads = [_]protocol.FindingCandidatePayload{.{ .findings = &span }};
    try std.testing.expectError(
        error.InvalidCandidateLocation,
        buildAlloc(
            allocator,
            try testInput(&fixture, &summary, &gapped_units, &span_payloads),
            verifier.port(),
        ),
    );
}

test "AI review producer domain rejects candidate side and unit path mismatches" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    const crossed = [_]protocol.FindingCandidate{.{
        .start_location = .{ .side = .before, .ordinal = 1 },
        .end_location = .{ .side = .after, .ordinal = 1 },
        .severity = .info,
        .title = "Crossed",
        .body = "Sides differ.",
    }};
    const units = [_]protocol.ReviewUnit{fixture.unit.value};
    const payloads = [_]protocol.FindingCandidatePayload{.{ .findings = &crossed }};
    var verifier: RecordingVerifier = .{};
    try std.testing.expectError(
        error.InvalidInput,
        buildAlloc(
            allocator,
            try testInput(&fixture, &fixture.summary.value, &units, &payloads),
            verifier.port(),
        ),
    );

    var locations = [_]protocol.ReviewLocation{
        fixture.unit.value.locations[0],
        fixture.unit.value.locations[1],
        fixture.unit.value.locations[2],
        fixture.unit.value.locations[3],
    };
    locations[3].path_bytes = "other.zig";
    var invalid_unit = fixture.unit.value;
    invalid_unit.locations = &locations;
    const invalid_units = [_]protocol.ReviewUnit{invalid_unit};
    const valid_payloads = [_]protocol.FindingCandidatePayload{fixture.candidate.value};
    try std.testing.expectError(
        error.InvalidInput,
        buildAlloc(
            allocator,
            try testInput(&fixture, &fixture.summary.value, &invalid_units, &valid_payloads),
            verifier.port(),
        ),
    );
}

test "AI review producer domain enforces per-unit and total finding limits" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    var too_many = [_]protocol.FindingCandidate{fixture.candidate.value.findings[0]} **
        (limits.max_findings_per_unit + 1);
    const one_unit = [_]protocol.ReviewUnit{fixture.unit.value};
    const oversized = [_]protocol.FindingCandidatePayload{.{ .findings = &too_many }};
    const verifier: AnchorVerifier = .{ .verify_fn = acceptAnchor };
    try std.testing.expectError(
        error.CandidateLimitExceeded,
        buildAlloc(
            allocator,
            try testInput(&fixture, &fixture.summary.value, &one_unit, &oversized),
            verifier,
        ),
    );

    const unit_count = limits.max_findings_total / limits.max_findings_per_unit + 1;
    const units = try allocator.alloc(protocol.ReviewUnit, unit_count);
    defer allocator.free(units);
    const payloads = try allocator.alloc(protocol.FindingCandidatePayload, unit_count);
    defer allocator.free(payloads);
    const full = [_]protocol.FindingCandidate{fixture.candidate.value.findings[0]} **
        limits.max_findings_per_unit;
    for (units, payloads, 0..) |*unit, *payload, index| {
        unit.* = fixture.unit.value;
        unit.unit_id = .{ .ordinal = @intCast(index + 1) };
        unit.ordinal = @intCast(index + 1);
        unit.unit_count = @intCast(unit_count);
        payload.* = .{ .findings = &full };
    }
    var summary = fixture.summary.value;
    summary.unit_count = @intCast(unit_count);
    try bindTestPlan(allocator, &summary, units);
    try std.testing.expectError(
        error.CandidateLimitExceeded,
        buildAlloc(allocator, try testInput(&fixture, &summary, units, payloads), verifier),
    );
}

test "AI review producer domain enforces the aggregate canonical candidate byte limit" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    const body = try allocator.alloc(u8, limits.max_body_bytes);
    defer allocator.free(body);
    @memset(body, 'b');
    const suggestion = try allocator.alloc(u8, limits.max_suggestion_bytes);
    defer allocator.free(suggestion);
    @memset(suggestion, 's');
    const large = protocol.FindingCandidate{
        .start_location = .{ .side = .after, .ordinal = 2 },
        .end_location = .{ .side = .after, .ordinal = 2 },
        .severity = .warning,
        .title = "Bounded",
        .body = body,
        .suggestion = suggestion,
    };
    const pair = [_]protocol.FindingCandidate{ large, large };
    const units = try allocator.alloc(protocol.ReviewUnit, limits.max_review_units);
    defer allocator.free(units);
    const payloads = try allocator.alloc(protocol.FindingCandidatePayload, limits.max_review_units);
    defer allocator.free(payloads);
    for (units, payloads, 0..) |*unit, *payload, index| {
        unit.* = fixture.unit.value;
        unit.unit_id = .{ .ordinal = @intCast(index + 1) };
        unit.ordinal = @intCast(index + 1);
        unit.unit_count = limits.max_review_units;
        payload.* = .{ .findings = &pair };
    }
    var summary = fixture.summary.value;
    summary.unit_count = limits.max_review_units;
    try bindTestPlan(allocator, &summary, units);
    const verifier: AnchorVerifier = .{ .verify_fn = acceptAnchor };
    try std.testing.expectError(
        error.CandidateLimitExceeded,
        buildAlloc(allocator, try testInput(&fixture, &summary, units, payloads), verifier),
    );
}

test "AI review producer domain rejects invalid artifact metadata" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    const units = [_]protocol.ReviewUnit{fixture.unit.value};
    const candidates = [_]protocol.FindingCandidatePayload{fixture.candidate.value};
    var input = try testInput(&fixture, &fixture.summary.value, &units, &candidates);
    input.created_at = "not-a-utc-second";
    const verifier: AnchorVerifier = .{ .verify_fn = acceptAnchor };
    try std.testing.expectError(error.InvalidArtifact, buildAlloc(allocator, input, verifier));
}

test "AI review producer domain matches canonical artifact goldens byte for byte" {
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init(allocator);
    defer fixture.deinit();
    const units = [_]protocol.ReviewUnit{fixture.unit.value};
    const candidates = [_]protocol.FindingCandidatePayload{fixture.candidate.value};
    const verifier: AnchorVerifier = .{ .verify_fn = acceptAnchor };
    var bundle = try buildAlloc(
        allocator,
        try testInput(&fixture, &fixture.summary.value, &units, &candidates),
        verifier,
    );
    defer bundle.deinit(allocator);
    const expected_findings = try readFixture(
        allocator,
        "testdata/ai-review-producer-v1/artifact/findings.json",
    );
    defer allocator.free(expected_findings);
    const expected_manifest = try readFixture(
        allocator,
        "testdata/ai-review-producer-v1/artifact/manifest.json",
    );
    defer allocator.free(expected_manifest);
    try std.testing.expectEqualSlices(u8, expected_findings, bundle.findings_bytes);
    try std.testing.expectEqualSlices(u8, expected_manifest, bundle.manifest_bytes);
}
