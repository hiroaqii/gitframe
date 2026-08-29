//! Exact, pure projection of committed-review Findings onto parsed diff model
//! coordinates. This module performs no Git, Store, App, or rendering work.

const std = @import("std");
const committed = @import("../committed_review.zig");
const diff_parser = @import("../diff/parser.zig");
const git_review = @import("../git/committed_review.zig");

pub const BuildError = error{
    OutOfMemory,
    InvalidBinding,
    InvalidSource,
};

pub const Identity = struct {
    review_repository_id: committed.ReviewRepositoryId,
    review_id: committed.ReviewId,
    target: committed.CommittedReviewTarget,
    findings_digest: committed.Sha256Digest,
};

pub const Endpoint = struct {
    path_bytes: []u8,
    object_oid: committed.ObjectId,
    mode: [6]u8,
    is_blob: bool,

    fn deinit(self: *Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.path_bytes);
        self.* = undefined;
    }
};

pub const Summary = struct {
    total: usize = 0,
    mapped: usize = 0,
    unmapped: usize = 0,
    stale: usize = 0,
    failed: usize = 0,
    info: usize = 0,
    warning: usize = 0,
    @"error": usize = 0,
};

pub const FileRecord = struct {
    ordinal: usize,
    status_bytes: []u8,
    before: ?Endpoint,
    after: ?Endpoint,
    summary: Summary = .{},
    mapped_entry_indices: []usize = &.{},

    fn deinit(self: *FileRecord, allocator: std.mem.Allocator) void {
        if (self.mapped_entry_indices.len != 0) allocator.free(self.mapped_entry_indices);
        if (self.after) |*endpoint_value| endpoint_value.deinit(allocator);
        if (self.before) |*endpoint_value| endpoint_value.deinit(allocator);
        allocator.free(self.status_bytes);
        self.* = undefined;
    }
};

pub const ModelSpan = struct {
    file_ordinal: usize,
    hunk_ordinal: usize,
    first_diff_line_ordinal: usize,
    last_diff_line_ordinal: usize,
};

pub const UnmappedReason = enum {
    endpoint_absent,
    endpoint_non_unique,
    range_not_visible,
};

pub const StaleReason = enum {
    invalid_anchor,
    path_not_found,
    path_not_blob,
    binary_blob,
    range_out_of_bounds,
    content_digest_mismatch,
    endpoint_blob_mismatch,
};

pub const FailedReason = enum {
    blob_object_unavailable,
    blob_too_large,
    anchor_git_command_failed,
};

pub const Outcome = union(enum) {
    mapped: ModelSpan,
    unmapped: UnmappedReason,
    stale: StaleReason,
    failed: FailedReason,
};

pub const Entry = struct {
    finding_id: []u8,
    severity: committed.Severity,
    anchor_path_bytes: []u8,
    side: committed.AnchorSide,
    start_line: u32,
    end_line: u32,
    content_digest: committed.Sha256Digest,
    /// Present only after one exact side/path endpoint association.
    file_ordinal: ?usize,
    outcome: Outcome,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.anchor_path_bytes);
        allocator.free(self.finding_id);
        self.* = undefined;
    }
};

pub const FindingProjectionIndex = struct {
    identity: Identity,
    files: []FileRecord,
    entries: []Entry,
    summary: Summary,
    mapped_entry_indices: []usize,

    pub fn deinit(self: *FindingProjectionIndex, allocator: std.mem.Allocator) void {
        if (self.mapped_entry_indices.len != 0) allocator.free(self.mapped_entry_indices);
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }
};

pub const BuildInput = struct {
    expected_review_repository_id: committed.ReviewRepositoryId,
    requested_review_id: committed.ReviewId,
    projection_target: committed.CommittedReviewTarget,
    manifest: *const committed.ReviewRunManifest,
    findings_bytes: []const u8,
    finding_set: *const committed.FindingSet,
    projection: *const git_review.CommittedDiffProjection,
    endpoints: *const git_review.CommittedDiffEndpointSidecar,
    anchor_validations: []const git_review.CodeAnchorValidation,
};

/// Build one immutable exact-run index. Structural disagreement fails the
/// whole build; only per-Finding anchor/mapping terminals become outcomes.
pub fn build(allocator: std.mem.Allocator, input: BuildInput) BuildError!FindingProjectionIndex {
    try validateBinding(input);
    var document = diff_parser.parse(allocator, input.projection.patch_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSource,
    };
    defer document.deinit(allocator);
    if (!input.endpoints.validFor(input.projection_target, document.files.len)) return error.InvalidSource;

    var files_list: std.ArrayList(FileRecord) = .empty;
    defer files_list.deinit(allocator);
    errdefer for (files_list.items) |*file| file.deinit(allocator);
    for (input.endpoints.records) |record| {
        var cloned = try cloneFileRecord(allocator, record);
        errdefer cloned.deinit(allocator);
        try files_list.append(allocator, cloned);
    }
    const files = try files_list.toOwnedSlice(allocator);
    errdefer deinitFiles(allocator, files);

    var entries_list: std.ArrayList(Entry) = .empty;
    defer entries_list.deinit(allocator);
    errdefer for (entries_list.items) |*entry| entry.deinit(allocator);
    var global_summary: Summary = .{};
    for (input.finding_set.findings, input.anchor_validations) |finding, validation| {
        const association = findEndpointAssociation(files, finding.anchor);
        const file_ordinal: ?usize = switch (association) {
            .unique => |ordinal| ordinal,
            .absent, .non_unique => null,
        };
        const outcome = projectFinding(document, files, finding.anchor, validation, association);
        const finding_id = try allocator.dupe(u8, finding.finding_id.bytes);
        errdefer allocator.free(finding_id);
        const anchor_path_bytes = try allocator.dupe(u8, finding.anchor.path_bytes);
        errdefer allocator.free(anchor_path_bytes);
        try entries_list.append(allocator, .{
            .finding_id = finding_id,
            .severity = finding.severity,
            .anchor_path_bytes = anchor_path_bytes,
            .side = finding.anchor.side,
            .start_line = finding.anchor.start_line,
            .end_line = finding.anchor.end_line,
            .content_digest = finding.anchor.content_digest,
            .file_ordinal = file_ordinal,
            .outcome = outcome,
        });
        addSummary(&global_summary, finding.severity, outcome);
        if (file_ordinal) |ordinal| addSummary(&files[ordinal].summary, finding.severity, outcome);
    }
    const entries = try entries_list.toOwnedSlice(allocator);
    errdefer deinitEntries(allocator, entries);

    var mapped_list: std.ArrayList(usize) = .empty;
    defer mapped_list.deinit(allocator);
    for (entries, 0..) |entry, index| if (entry.outcome == .mapped) try mapped_list.append(allocator, index);
    std.mem.sort(usize, mapped_list.items, entries, mappedEntryLessThan);
    const mapped_indices = try mapped_list.toOwnedSlice(allocator);
    errdefer allocator.free(mapped_indices);

    try populateFileNavigation(allocator, files, entries, mapped_indices);
    return .{
        .identity = .{
            .review_repository_id = input.expected_review_repository_id,
            .review_id = input.requested_review_id,
            .target = input.projection_target,
            .findings_digest = input.manifest.findings_digest,
        },
        .files = files,
        .entries = entries,
        .summary = global_summary,
        .mapped_entry_indices = mapped_indices,
    };
}

fn validateBinding(input: BuildInput) BuildError!void {
    input.projection_target.validate() catch return error.InvalidBinding;
    if (!input.manifest.review_repository_id.eql(input.expected_review_repository_id) or
        !input.manifest.review_id.eql(input.requested_review_id) or
        !input.finding_set.review_id.eql(input.requested_review_id) or
        !input.manifest.target.eql(&input.projection_target) or
        !input.finding_set.target.eql(&input.projection_target) or
        !input.projection.target.eql(&input.projection_target) or
        !input.endpoints.target.eql(&input.projection_target) or
        input.finding_set.findings.len != input.anchor_validations.len)
    {
        return error.InvalidBinding;
    }
    input.manifest.validateFindingSet(input.findings_bytes, input.finding_set) catch
        return error.InvalidBinding;
}

fn cloneFileRecord(
    allocator: std.mem.Allocator,
    source: git_review.CommittedDiffEndpointRecord,
) std.mem.Allocator.Error!FileRecord {
    var before = if (source.before) |endpoint_value| try cloneEndpoint(allocator, endpoint_value) else null;
    errdefer if (before) |*endpoint_value| endpoint_value.deinit(allocator);
    var after = if (source.after) |endpoint_value| try cloneEndpoint(allocator, endpoint_value) else null;
    errdefer if (after) |*endpoint_value| endpoint_value.deinit(allocator);
    const status_bytes = try allocator.dupe(u8, source.status_bytes);
    return .{
        .ordinal = source.file_ordinal,
        .status_bytes = status_bytes,
        .before = before,
        .after = after,
    };
}

fn cloneEndpoint(
    allocator: std.mem.Allocator,
    source: git_review.CommittedDiffEndpoint,
) std.mem.Allocator.Error!Endpoint {
    return .{
        .path_bytes = try allocator.dupe(u8, source.path_bytes),
        .object_oid = source.object_oid,
        .mode = source.mode,
        .is_blob = source.is_blob,
    };
}

const EndpointAssociation = union(enum) { absent, non_unique, unique: usize };

fn findEndpointAssociation(files: []const FileRecord, anchor: committed.CodeAnchor) EndpointAssociation {
    var ordinal: ?usize = null;
    for (files) |file| {
        const endpoint_value = switch (anchor.side) {
            .before => file.before,
            .after => file.after,
        } orelse continue;
        if (!std.mem.eql(u8, endpoint_value.path_bytes, anchor.path_bytes)) continue;
        if (ordinal != null) return .non_unique;
        ordinal = file.ordinal;
    }
    return if (ordinal) |value| .{ .unique = value } else .absent;
}

fn projectFinding(
    document: diff_parser.DiffDocument,
    files: []const FileRecord,
    anchor: committed.CodeAnchor,
    validation: git_review.CodeAnchorValidation,
    association: EndpointAssociation,
) Outcome {
    const blob_oid = switch (validation) {
        .failure => |failure| return outcomeFromAnchorFailure(failure),
        .validated => |value| value,
    };
    const file_ordinal = switch (association) {
        .absent => return .{ .unmapped = .endpoint_absent },
        .non_unique => return .{ .unmapped = .endpoint_non_unique },
        .unique => |ordinal| ordinal,
    };
    const endpoint_value = switch (anchor.side) {
        .before => files[file_ordinal].before.?,
        .after => files[file_ordinal].after.?,
    };
    if (!endpoint_value.is_blob or !endpoint_value.object_oid.eql(&blob_oid))
        return .{ .stale = .endpoint_blob_mismatch };
    const span = visibleModelSpan(document.files[file_ordinal], file_ordinal, anchor) orelse
        return .{ .unmapped = .range_not_visible };
    return .{ .mapped = span };
}

fn outcomeFromAnchorFailure(failure: git_review.CodeAnchorFailure) Outcome {
    return switch (failure) {
        .invalid_anchor => .{ .stale = .invalid_anchor },
        .path_not_found => .{ .stale = .path_not_found },
        .path_not_blob => .{ .stale = .path_not_blob },
        .binary_blob => .{ .stale = .binary_blob },
        .range_out_of_bounds => .{ .stale = .range_out_of_bounds },
        .content_digest_mismatch => .{ .stale = .content_digest_mismatch },
        .blob_object_unavailable => .{ .failed = .blob_object_unavailable },
        .blob_too_large => .{ .failed = .blob_too_large },
        .anchor_git_command_failed => .{ .failed = .anchor_git_command_failed },
    };
}

fn visibleModelSpan(
    file: diff_parser.FileDiff,
    file_ordinal: usize,
    anchor: committed.CodeAnchor,
) ?ModelSpan {
    var found: ?ModelSpan = null;
    for (file.hunks, 0..) |hunk, hunk_ordinal| {
        var expected = anchor.start_line;
        var first: ?usize = null;
        var last: usize = 0;
        var complete = false;
        var invalid = false;
        for (hunk.lines, 0..) |line, line_ordinal| {
            const source_line = switch (anchor.side) {
                .before => line.old_line,
                .after => line.new_line,
            } orelse continue;
            if (source_line < anchor.start_line or source_line > anchor.end_line) continue;
            if (complete or source_line != expected) {
                invalid = true;
                break;
            }
            if (first == null) first = line_ordinal;
            last = line_ordinal;
            if (source_line == anchor.end_line) {
                complete = true;
            } else {
                expected += 1;
            }
        }
        if (invalid or !complete) continue;
        if (found != null) return null;
        found = .{
            .file_ordinal = file_ordinal,
            .hunk_ordinal = hunk_ordinal,
            .first_diff_line_ordinal = first.?,
            .last_diff_line_ordinal = last,
        };
    }
    return found;
}

fn addSummary(summary: *Summary, severity: committed.Severity, outcome: Outcome) void {
    summary.total += 1;
    switch (outcome) {
        .mapped => summary.mapped += 1,
        .unmapped => summary.unmapped += 1,
        .stale => summary.stale += 1,
        .failed => summary.failed += 1,
    }
    switch (severity) {
        .info => summary.info += 1,
        .warning => summary.warning += 1,
        .@"error" => summary.@"error" += 1,
    }
}

fn mappedEntryLessThan(entries: []const Entry, left_index: usize, right_index: usize) bool {
    const left = entries[left_index];
    const right = entries[right_index];
    const left_span = left.outcome.mapped;
    const right_span = right.outcome.mapped;
    if (left_span.file_ordinal != right_span.file_ordinal)
        return left_span.file_ordinal < right_span.file_ordinal;
    if (left_span.hunk_ordinal != right_span.hunk_ordinal)
        return left_span.hunk_ordinal < right_span.hunk_ordinal;
    if (left_span.first_diff_line_ordinal != right_span.first_diff_line_ordinal)
        return left_span.first_diff_line_ordinal < right_span.first_diff_line_ordinal;
    if (left.side != right.side) return @intFromEnum(left.side) < @intFromEnum(right.side);
    if (left.start_line != right.start_line) return left.start_line < right.start_line;
    if (left.end_line != right.end_line) return left.end_line < right.end_line;
    return std.mem.order(u8, left.finding_id, right.finding_id) == .lt;
}

fn populateFileNavigation(
    allocator: std.mem.Allocator,
    files: []FileRecord,
    entries: []const Entry,
    mapped_indices: []const usize,
) std.mem.Allocator.Error!void {
    const counts = try allocator.alloc(usize, files.len);
    defer allocator.free(counts);
    @memset(counts, 0);
    for (mapped_indices) |entry_index| counts[entries[entry_index].outcome.mapped.file_ordinal] += 1;
    for (files, counts) |*file, count| file.mapped_entry_indices = try allocator.alloc(usize, count);
    @memset(counts, 0);
    for (mapped_indices) |entry_index| {
        const ordinal = entries[entry_index].outcome.mapped.file_ordinal;
        files[ordinal].mapped_entry_indices[counts[ordinal]] = entry_index;
        counts[ordinal] += 1;
    }
}

fn deinitFiles(allocator: std.mem.Allocator, files: []FileRecord) void {
    for (files) |*file| file.deinit(allocator);
    allocator.free(files);
}

fn deinitEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn testObjectId(byte: u8) committed.ObjectId {
    var oid: committed.ObjectId = .{ .len = 40 };
    @memset(oid.bytes[0..40], byte);
    return oid;
}

fn testTarget() committed.CommittedReviewTarget {
    return .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = testObjectId('1'),
        .head_oid = testObjectId('2'),
        .diff_base_oid = testObjectId('1'),
    };
}

fn testEndpoint(
    allocator: std.mem.Allocator,
    path: []const u8,
    oid: committed.ObjectId,
) !git_review.CommittedDiffEndpoint {
    return .{
        .path_bytes = try allocator.dupe(u8, path),
        .object_oid = oid,
        .mode = .{ '1', '0', '0', '6', '4', '4' },
        .is_blob = true,
    };
}

test "finding projection preserves exact mapped and closed non-mapped outcomes" {
    const allocator = std.testing.allocator;
    const target = testTarget();
    const repository_id = try committed.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const review_id = try committed.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const alternate_review_id = try committed.ReviewId.parse("323e4567-e89b-42d3-a456-426614174000");
    const old_oid = testObjectId('a');
    const new_oid = testObjectId('b');
    const patch_text =
        "diff --git a/src/a.zig b/src/a.zig\n" ++
        "index aaaaaaa..bbbbbbb 100644\n" ++
        "--- a/src/a.zig\n" ++
        "+++ b/src/a.zig\n" ++
        "@@ -1,3 +1,3 @@\n" ++
        " one\n" ++
        "-old\n" ++
        "+new\n" ++
        " three\n";
    var projection: git_review.CommittedDiffProjection = .{
        .target = target,
        .patch_bytes = try allocator.dupe(u8, patch_text),
    };
    defer projection.deinit(allocator);
    var records = try allocator.alloc(git_review.CommittedDiffEndpointRecord, 1);
    records[0] = .{
        .file_ordinal = 0,
        .status_bytes = try allocator.dupe(u8, "M"),
        .old_mode = .{ '1', '0', '0', '6', '4', '4' },
        .new_mode = .{ '1', '0', '0', '6', '4', '4' },
        .before = try testEndpoint(allocator, "src/a.zig", old_oid),
        .after = try testEndpoint(allocator, "src/a.zig", new_oid),
    };
    var endpoints: git_review.CommittedDiffEndpointSidecar = .{ .target = target, .records = records };
    defer endpoints.deinit(allocator);

    const ids = [_][]const u8{
        "finding-after",   "finding-before",       "finding-invisible", "finding-absent", "finding-blob-mismatch",
        "finding-invalid", "finding-path-missing", "finding-path-type", "finding-binary", "finding-range",
        "finding-digest",  "finding-object",       "finding-large",     "finding-git",
    };
    var findings: [ids.len]committed.Finding = undefined;
    for (&findings, ids, 0..) |*finding, id, index| {
        finding.* = .{
            .finding_id = .{ .bytes = id },
            .anchor = .{
                .path_bytes = "src/a.zig",
                .side = .after,
                .start_line = 2,
                .end_line = 2,
                .content_digest = committed.Sha256Digest.hash("new\n"),
            },
            .severity = switch (index % 3) {
                0 => .info,
                1 => .warning,
                else => .@"error",
            },
            .title = "title",
            .body = "body",
        };
    }
    findings[1].anchor.side = .before;
    findings[1].anchor.content_digest = committed.Sha256Digest.hash("old\n");
    findings[2].anchor.start_line = 99;
    findings[2].anchor.end_line = 99;
    findings[3].anchor.path_bytes = "src/absent.zig";

    var validations = [_]git_review.CodeAnchorValidation{.{ .validated = new_oid }} ** ids.len;
    validations[1] = .{ .validated = old_oid };
    validations[4] = .{ .validated = old_oid };
    const failures = [_]git_review.CodeAnchorFailure{
        .invalid_anchor,
        .path_not_found,
        .path_not_blob,
        .binary_blob,
        .range_out_of_bounds,
        .content_digest_mismatch,
        .blob_object_unavailable,
        .blob_too_large,
        .anchor_git_command_failed,
    };
    for (failures, 5..) |failure, index| validations[index] = .{ .failure = failure };

    const producer: committed.Producer = .{ .name = "test" };
    const findings_bytes = "exact findings bytes\n";
    const finding_set: committed.FindingSet = .{
        .schema_version = 1,
        .review_id = review_id,
        .created_at = "2026-08-29T00:00:00Z",
        .target = target,
        .producer = producer,
        .findings = &findings,
    };
    const manifest: committed.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = review_id,
        .review_repository_id = repository_id,
        .target = target,
        .created_at = finding_set.created_at,
        .display = null,
        .finding_count = findings.len,
        .producer = producer,
        .findings_digest = committed.Sha256Digest.hash(findings_bytes),
    };
    const input: BuildInput = .{
        .expected_review_repository_id = repository_id,
        .requested_review_id = review_id,
        .projection_target = target,
        .manifest = &manifest,
        .findings_bytes = findings_bytes,
        .finding_set = &finding_set,
        .projection = &projection,
        .endpoints = &endpoints,
        .anchor_validations = &validations,
    };

    var wrong_identity = input;
    wrong_identity.requested_review_id = alternate_review_id;
    try std.testing.expectError(error.InvalidBinding, build(allocator, wrong_identity));
    endpoints.records[0].file_ordinal = 1;
    try std.testing.expectError(error.InvalidSource, build(allocator, input));
    endpoints.records[0].file_ordinal = 0;

    var index = try build(allocator, input);
    defer index.deinit(allocator);
    try std.testing.expectEqual(findings.len, index.entries.len);
    try std.testing.expectEqual(findings.len, index.summary.total);
    try std.testing.expectEqual(@as(usize, 2), index.summary.mapped);
    try std.testing.expectEqual(@as(usize, 2), index.summary.unmapped);
    try std.testing.expectEqual(@as(usize, 7), index.summary.stale);
    try std.testing.expectEqual(@as(usize, 3), index.summary.failed);
    try std.testing.expectEqual(@as(usize, 5), index.summary.info);
    try std.testing.expectEqual(@as(usize, 5), index.summary.warning);
    try std.testing.expectEqual(@as(usize, 4), index.summary.@"error");
    try std.testing.expectEqual(@as(usize, 13), index.files[0].summary.total);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, index.mapped_entry_indices);
    try std.testing.expectEqualSlices(usize, index.mapped_entry_indices, index.files[0].mapped_entry_indices);
    try std.testing.expectEqual(UnmappedReason.range_not_visible, index.entries[2].outcome.unmapped);
    try std.testing.expectEqual(UnmappedReason.endpoint_absent, index.entries[3].outcome.unmapped);
    try std.testing.expectEqual(StaleReason.endpoint_blob_mismatch, index.entries[4].outcome.stale);

    const expected_outcomes = [_]Outcome{
        .{ .stale = .invalid_anchor },
        .{ .stale = .path_not_found },
        .{ .stale = .path_not_blob },
        .{ .stale = .binary_blob },
        .{ .stale = .range_out_of_bounds },
        .{ .stale = .content_digest_mismatch },
        .{ .failed = .blob_object_unavailable },
        .{ .failed = .blob_too_large },
        .{ .failed = .anchor_git_command_failed },
    };
    for (expected_outcomes, 5..) |expected, index_value| {
        try std.testing.expectEqual(expected, index.entries[index_value].outcome);
    }
    try std.testing.expect(index.entries[0].finding_id.ptr != findings[0].finding_id.bytes.ptr);
    try std.testing.expect(index.entries[0].anchor_path_bytes.ptr != findings[0].anchor.path_bytes.ptr);
    try std.testing.expect(index.files[0].after.?.path_bytes.ptr != endpoints.records[0].after.?.path_bytes.ptr);
}

test "finding projection keeps exact rename raw-path navigation and run identity" {
    const allocator = std.testing.allocator;
    const target = testTarget();
    const repository_id = try committed.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const alternate_repository_id = try committed.ReviewRepositoryId.parse("223e4567-e89b-42d3-a456-426614174000");
    const review_id = try committed.ReviewId.parse("323e4567-e89b-42d3-a456-426614174000");
    const alternate_review_id = try committed.ReviewId.parse("423e4567-e89b-42d3-a456-426614174000");
    const old_oid = testObjectId('a');
    const new_oid = testObjectId('b');
    const raw_old_oid = testObjectId('c');
    const raw_new_oid = testObjectId('d');
    const raw_path = "raw-\xff.zig";
    const patch_text =
        "diff --git a/old-name.zig b/new-name.zig\n" ++
        "similarity index 75%\n" ++
        "rename from old-name.zig\n" ++
        "rename to new-name.zig\n" ++
        "index aaaaaaa..bbbbbbb 100644\n" ++
        "--- a/old-name.zig\n" ++
        "+++ b/new-name.zig\n" ++
        "@@ -1,4 +1,4 @@\n" ++
        " context-one\n" ++
        "-old-two\n" ++
        "+new-two\n" ++
        " context-three\n" ++
        " context-four\n" ++
        "diff --git \"a/raw-\\377.zig\" \"b/raw-\\377.zig\"\n" ++
        "index ccccccc..ddddddd 100644\n" ++
        "--- a/raw-\xff.zig\n" ++
        "+++ b/raw-\xff.zig\n" ++
        "@@ -1 +1,2 @@\n" ++
        " raw-one\n" ++
        "+raw-two\n";
    var projection: git_review.CommittedDiffProjection = .{
        .target = target,
        .patch_bytes = try allocator.dupe(u8, patch_text),
    };
    defer projection.deinit(allocator);
    var records = try allocator.alloc(git_review.CommittedDiffEndpointRecord, 2);
    records[0] = .{
        .file_ordinal = 0,
        .status_bytes = try allocator.dupe(u8, "R075"),
        .old_mode = .{ '1', '0', '0', '6', '4', '4' },
        .new_mode = .{ '1', '0', '0', '6', '4', '4' },
        .before = try testEndpoint(allocator, "old-name.zig", old_oid),
        .after = try testEndpoint(allocator, "new-name.zig", new_oid),
    };
    records[1] = .{
        .file_ordinal = 1,
        .status_bytes = try allocator.dupe(u8, "M"),
        .old_mode = .{ '1', '0', '0', '6', '4', '4' },
        .new_mode = .{ '1', '0', '0', '6', '4', '4' },
        .before = try testEndpoint(allocator, raw_path, raw_old_oid),
        .after = try testEndpoint(allocator, raw_path, raw_new_oid),
    };
    var endpoints: git_review.CommittedDiffEndpointSidecar = .{ .target = target, .records = records };
    defer endpoints.deinit(allocator);

    const FindingCase = struct {
        id: []const u8,
        path: []const u8,
        side: committed.AnchorSide,
        start_line: u32,
        end_line: u32,
        digest_text: []const u8,
        severity: committed.Severity,
        oid: committed.ObjectId,
        file_ordinal: usize,
        first_diff_line_ordinal: usize,
        last_diff_line_ordinal: usize,
    };
    const cases = [_]FindingCase{
        .{ .id = "side-before", .path = "old-name.zig", .side = .before, .start_line = 1, .end_line = 1, .digest_text = "context-one\n", .severity = .info, .oid = old_oid, .file_ordinal = 0, .first_diff_line_ordinal = 0, .last_diff_line_ordinal = 0 },
        .{ .id = "tie-z", .path = "new-name.zig", .side = .after, .start_line = 1, .end_line = 1, .digest_text = "context-one\n", .severity = .warning, .oid = new_oid, .file_ordinal = 0, .first_diff_line_ordinal = 0, .last_diff_line_ordinal = 0 },
        .{ .id = "tie-a", .path = "new-name.zig", .side = .after, .start_line = 1, .end_line = 1, .digest_text = "context-one\n", .severity = .@"error", .oid = new_oid, .file_ordinal = 0, .first_diff_line_ordinal = 0, .last_diff_line_ordinal = 0 },
        .{ .id = "range-wide", .path = "new-name.zig", .side = .after, .start_line = 1, .end_line = 3, .digest_text = "context-one\nnew-two\ncontext-three\n", .severity = .info, .oid = new_oid, .file_ordinal = 0, .first_diff_line_ordinal = 0, .last_diff_line_ordinal = 3 },
        .{ .id = "deleted-before", .path = "old-name.zig", .side = .before, .start_line = 2, .end_line = 2, .digest_text = "old-two\n", .severity = .warning, .oid = old_oid, .file_ordinal = 0, .first_diff_line_ordinal = 1, .last_diff_line_ordinal = 1 },
        .{ .id = "added-z", .path = "new-name.zig", .side = .after, .start_line = 2, .end_line = 2, .digest_text = "new-two\n", .severity = .@"error", .oid = new_oid, .file_ordinal = 0, .first_diff_line_ordinal = 2, .last_diff_line_ordinal = 2 },
        .{ .id = "added-a", .path = "new-name.zig", .side = .after, .start_line = 2, .end_line = 2, .digest_text = "new-two\n", .severity = .info, .oid = new_oid, .file_ordinal = 0, .first_diff_line_ordinal = 2, .last_diff_line_ordinal = 2 },
        .{ .id = "context-after", .path = "new-name.zig", .side = .after, .start_line = 3, .end_line = 3, .digest_text = "context-three\n", .severity = .warning, .oid = new_oid, .file_ordinal = 0, .first_diff_line_ordinal = 3, .last_diff_line_ordinal = 3 },
        .{ .id = "raw-after", .path = raw_path, .side = .after, .start_line = 2, .end_line = 2, .digest_text = "raw-two\n", .severity = .@"error", .oid = raw_new_oid, .file_ordinal = 1, .first_diff_line_ordinal = 1, .last_diff_line_ordinal = 1 },
        .{ .id = "raw-before", .path = raw_path, .side = .before, .start_line = 1, .end_line = 1, .digest_text = "raw-one\n", .severity = .info, .oid = raw_old_oid, .file_ordinal = 1, .first_diff_line_ordinal = 0, .last_diff_line_ordinal = 0 },
    };
    var findings: [cases.len]committed.Finding = undefined;
    var validations: [cases.len]git_review.CodeAnchorValidation = undefined;
    for (&findings, &validations, cases) |*finding, *validation, case| {
        finding.* = .{
            .finding_id = .{ .bytes = case.id },
            .anchor = .{
                .path_bytes = case.path,
                .side = case.side,
                .start_line = case.start_line,
                .end_line = case.end_line,
                .content_digest = committed.Sha256Digest.hash(case.digest_text),
            },
            .severity = case.severity,
            .title = "title",
            .body = "body",
        };
        validation.* = .{ .validated = case.oid };
    }

    const producer: committed.Producer = .{ .name = "test" };
    const findings_bytes = "navigation findings bytes\n";
    const finding_set: committed.FindingSet = .{
        .schema_version = 1,
        .review_id = review_id,
        .created_at = "2026-08-29T00:00:00Z",
        .target = target,
        .producer = producer,
        .findings = &findings,
    };
    const manifest: committed.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = review_id,
        .review_repository_id = repository_id,
        .target = target,
        .created_at = finding_set.created_at,
        .display = null,
        .finding_count = findings.len,
        .producer = producer,
        .findings_digest = committed.Sha256Digest.hash(findings_bytes),
    };
    const input: BuildInput = .{
        .expected_review_repository_id = repository_id,
        .requested_review_id = review_id,
        .projection_target = target,
        .manifest = &manifest,
        .findings_bytes = findings_bytes,
        .finding_set = &finding_set,
        .projection = &projection,
        .endpoints = &endpoints,
        .anchor_validations = &validations,
    };
    var index = try build(allocator, input);
    defer index.deinit(allocator);

    try std.testing.expectEqual(@as(usize, cases.len), index.summary.total);
    try std.testing.expectEqual(@as(usize, cases.len), index.summary.mapped);
    try std.testing.expectEqual(@as(usize, 0), index.summary.unmapped);
    try std.testing.expectEqual(@as(usize, 0), index.summary.stale);
    try std.testing.expectEqual(@as(usize, 0), index.summary.failed);
    try std.testing.expectEqual(@as(usize, 4), index.summary.info);
    try std.testing.expectEqual(@as(usize, 3), index.summary.warning);
    try std.testing.expectEqual(@as(usize, 3), index.summary.@"error");
    try std.testing.expectEqual(Summary{ .total = 8, .mapped = 8, .info = 3, .warning = 3, .@"error" = 2 }, index.files[0].summary);
    try std.testing.expectEqual(Summary{ .total = 2, .mapped = 2, .info = 1, .@"error" = 1 }, index.files[1].summary);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 1, 3, 4, 6, 5, 7, 9, 8 }, index.mapped_entry_indices);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 1, 3, 4, 6, 5, 7 }, index.files[0].mapped_entry_indices);
    try std.testing.expectEqualSlices(usize, &.{ 9, 8 }, index.files[1].mapped_entry_indices);
    for (index.entries, cases) |entry, case| {
        try std.testing.expectEqualStrings(case.id, entry.finding_id);
        try std.testing.expectEqualSlices(u8, case.path, entry.anchor_path_bytes);
        try std.testing.expectEqual(case.side, entry.side);
        try std.testing.expectEqual(case.start_line, entry.start_line);
        try std.testing.expectEqual(case.end_line, entry.end_line);
        try std.testing.expectEqual(@as(?usize, case.file_ordinal), entry.file_ordinal);
        const span = switch (entry.outcome) {
            .mapped => |value| value,
            else => return error.ExpectedMappedFinding,
        };
        try std.testing.expectEqual(case.file_ordinal, span.file_ordinal);
        try std.testing.expectEqual(@as(usize, 0), span.hunk_ordinal);
        try std.testing.expectEqual(case.first_diff_line_ordinal, span.first_diff_line_ordinal);
        try std.testing.expectEqual(case.last_diff_line_ordinal, span.last_diff_line_ordinal);
    }
    try std.testing.expectEqualSlices(u8, "old-name.zig", index.files[0].before.?.path_bytes);
    try std.testing.expectEqualSlices(u8, "new-name.zig", index.files[0].after.?.path_bytes);
    try std.testing.expectEqualSlices(u8, raw_path, index.files[1].before.?.path_bytes);
    try std.testing.expectEqualSlices(u8, raw_path, index.files[1].after.?.path_bytes);

    var repository_manifest = manifest;
    repository_manifest.review_repository_id = alternate_repository_id;
    var repository_input = input;
    repository_input.expected_review_repository_id = alternate_repository_id;
    repository_input.manifest = &repository_manifest;
    var repository_index = try build(allocator, repository_input);
    defer repository_index.deinit(allocator);
    try std.testing.expect(!repository_index.identity.review_repository_id.eql(index.identity.review_repository_id));
    try std.testing.expect(repository_index.identity.review_id.eql(index.identity.review_id));
    try std.testing.expect(repository_index.identity.findings_digest.eql(index.identity.findings_digest));

    var review_manifest = manifest;
    review_manifest.review_id = alternate_review_id;
    var review_finding_set = finding_set;
    review_finding_set.review_id = alternate_review_id;
    var review_input = input;
    review_input.requested_review_id = alternate_review_id;
    review_input.manifest = &review_manifest;
    review_input.finding_set = &review_finding_set;
    var review_index = try build(allocator, review_input);
    defer review_index.deinit(allocator);
    try std.testing.expect(review_index.identity.review_repository_id.eql(index.identity.review_repository_id));
    try std.testing.expect(!review_index.identity.review_id.eql(index.identity.review_id));
    try std.testing.expect(review_index.identity.findings_digest.eql(index.identity.findings_digest));

    const alternate_findings_bytes = "alternate navigation findings bytes\n";
    var digest_manifest = manifest;
    digest_manifest.findings_digest = committed.Sha256Digest.hash(alternate_findings_bytes);
    var digest_input = input;
    digest_input.manifest = &digest_manifest;
    digest_input.findings_bytes = alternate_findings_bytes;
    var digest_index = try build(allocator, digest_input);
    defer digest_index.deinit(allocator);
    try std.testing.expect(digest_index.identity.review_repository_id.eql(index.identity.review_repository_id));
    try std.testing.expect(digest_index.identity.review_id.eql(index.identity.review_id));
    try std.testing.expect(!digest_index.identity.findings_digest.eql(index.identity.findings_digest));

    var mismatched_manifest = manifest;
    mismatched_manifest.review_repository_id = alternate_repository_id;
    var mismatched_input = input;
    mismatched_input.manifest = &mismatched_manifest;
    try std.testing.expectError(error.InvalidBinding, build(allocator, mismatched_input));
    var mismatched_finding_set = finding_set;
    mismatched_finding_set.review_id = alternate_review_id;
    mismatched_input = input;
    mismatched_input.finding_set = &mismatched_finding_set;
    try std.testing.expectError(error.InvalidBinding, build(allocator, mismatched_input));
    mismatched_input = input;
    mismatched_input.findings_bytes = alternate_findings_bytes;
    try std.testing.expectError(error.InvalidBinding, build(allocator, mismatched_input));
    var mismatched_projection = projection;
    mismatched_projection.target.head_oid = testObjectId('3');
    mismatched_input = input;
    mismatched_input.projection = &mismatched_projection;
    try std.testing.expectError(error.InvalidBinding, build(allocator, mismatched_input));
}

test "finding projection admits zero and schema-maximum Findings without a new limit" {
    const allocator = std.testing.allocator;
    const target = testTarget();
    const repository_id = try committed.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const review_id = try committed.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const producer: committed.Producer = .{ .name = "test" };
    const findings_bytes = "bounded findings\n";
    var projection: git_review.CommittedDiffProjection = .{
        .target = target,
        .patch_bytes = try allocator.alloc(u8, 0),
    };
    defer projection.deinit(allocator);
    var endpoints: git_review.CommittedDiffEndpointSidecar = .{
        .target = target,
        .records = try allocator.alloc(git_review.CommittedDiffEndpointRecord, 0),
    };
    defer endpoints.deinit(allocator);

    var finding_set: committed.FindingSet = .{
        .schema_version = 1,
        .review_id = review_id,
        .created_at = "2026-08-29T00:00:00Z",
        .target = target,
        .producer = producer,
        .findings = &.{},
    };
    var manifest: committed.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = review_id,
        .review_repository_id = repository_id,
        .target = target,
        .created_at = finding_set.created_at,
        .display = null,
        .finding_count = 0,
        .producer = producer,
        .findings_digest = committed.Sha256Digest.hash(findings_bytes),
    };
    var input: BuildInput = .{
        .expected_review_repository_id = repository_id,
        .requested_review_id = review_id,
        .projection_target = target,
        .manifest = &manifest,
        .findings_bytes = findings_bytes,
        .finding_set = &finding_set,
        .projection = &projection,
        .endpoints = &endpoints,
        .anchor_validations = &.{},
    };
    var empty = try build(allocator, input);
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);

    const findings = try allocator.alloc(committed.Finding, committed.limits.max_findings);
    defer allocator.free(findings);
    const finding_ids = try allocator.alloc([16]u8, committed.limits.max_findings);
    defer allocator.free(finding_ids);
    const validations = try allocator.alloc(git_review.CodeAnchorValidation, committed.limits.max_findings);
    defer allocator.free(validations);
    const oid = testObjectId('b');
    for (findings, validations, finding_ids, 0..) |*finding, *validation, *id_storage, index_value| {
        const finding_id = try std.fmt.bufPrint(id_storage, "finding-{d:0>4}", .{index_value});
        finding.* = .{
            .finding_id = .{ .bytes = finding_id },
            .anchor = .{
                .path_bytes = "unchanged.zig",
                .side = .after,
                .start_line = 1,
                .end_line = 1,
                .content_digest = committed.Sha256Digest.hash("line\n"),
            },
            .severity = .info,
            .title = "title",
            .body = "body",
        };
        validation.* = .{ .validated = oid };
    }
    finding_set.findings = findings;
    manifest.finding_count = committed.limits.max_findings;
    input.finding_set = &finding_set;
    input.manifest = &manifest;
    input.anchor_validations = validations;
    var maximum = try build(allocator, input);
    defer maximum.deinit(allocator);
    try std.testing.expectEqual(committed.limits.max_findings, maximum.entries.len);
    try std.testing.expectEqual(committed.limits.max_findings, maximum.summary.unmapped);
    try std.testing.expectEqual(@as(usize, 0), maximum.mapped_entry_indices.len);
}

test "finding projection fails closed on duplicate exact side-path endpoints" {
    const allocator = std.testing.allocator;
    const oid = testObjectId('a');
    const patch =
        "diff --git a/one.zig b/copy-one.zig\n" ++
        "--- a/one.zig\n" ++
        "+++ b/copy-one.zig\n" ++
        "@@ -1 +1 @@\n line\n" ++
        "diff --git a/one.zig b/copy-two.zig\n" ++
        "--- a/one.zig\n" ++
        "+++ b/copy-two.zig\n" ++
        "@@ -1 +1 @@\n line\n";
    var document = try diff_parser.parse(allocator, patch);
    defer document.deinit(allocator);
    const mode = [6]u8{ '1', '0', '0', '6', '4', '4' };
    const files = [_]FileRecord{
        .{
            .ordinal = 0,
            .status_bytes = @constCast("C100"),
            .before = .{ .path_bytes = @constCast("one.zig"), .object_oid = oid, .mode = mode, .is_blob = true },
            .after = .{ .path_bytes = @constCast("copy-one.zig"), .object_oid = oid, .mode = mode, .is_blob = true },
        },
        .{
            .ordinal = 1,
            .status_bytes = @constCast("C100"),
            .before = .{ .path_bytes = @constCast("one.zig"), .object_oid = oid, .mode = mode, .is_blob = true },
            .after = .{ .path_bytes = @constCast("copy-two.zig"), .object_oid = oid, .mode = mode, .is_blob = true },
        },
    };
    const anchor: committed.CodeAnchor = .{
        .path_bytes = "one.zig",
        .side = .before,
        .start_line = 1,
        .end_line = 1,
        .content_digest = committed.Sha256Digest.hash("line\n"),
    };
    const association = findEndpointAssociation(&files, anchor);
    try std.testing.expect(association == .non_unique);
    const outcome = projectFinding(document, &files, anchor, .{ .validated = oid }, association);
    try std.testing.expectEqual(UnmappedReason.endpoint_non_unique, outcome.unmapped);
}

fn exerciseFindingProjectionAllocations(allocator: std.mem.Allocator) !void {
    const target = testTarget();
    const repository_id = try committed.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const review_id = try committed.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const oid = testObjectId('b');
    const patch =
        "diff --git a/a.zig b/a.zig\n" ++
        "--- a/a.zig\n" ++
        "+++ b/a.zig\n" ++
        "@@ -1 +1 @@\n-old\n+new\n";
    var projection: git_review.CommittedDiffProjection = .{
        .target = target,
        .patch_bytes = @constCast(patch),
    };
    const mode = [6]u8{ '1', '0', '0', '6', '4', '4' };
    var records = [_]git_review.CommittedDiffEndpointRecord{.{
        .file_ordinal = 0,
        .status_bytes = @constCast("M"),
        .old_mode = mode,
        .new_mode = mode,
        .before = .{ .path_bytes = @constCast("a.zig"), .object_oid = testObjectId('a'), .mode = mode, .is_blob = true },
        .after = .{ .path_bytes = @constCast("a.zig"), .object_oid = oid, .mode = mode, .is_blob = true },
    }};
    var endpoints: git_review.CommittedDiffEndpointSidecar = .{ .target = target, .records = &records };
    const finding: committed.Finding = .{
        .finding_id = .{ .bytes = "finding-0001" },
        .anchor = .{
            .path_bytes = "a.zig",
            .side = .after,
            .start_line = 1,
            .end_line = 1,
            .content_digest = committed.Sha256Digest.hash("new\n"),
        },
        .severity = .warning,
        .title = "title",
        .body = "body",
    };
    const producer: committed.Producer = .{ .name = "test" };
    const findings_bytes = "allocation findings\n";
    const finding_set: committed.FindingSet = .{
        .schema_version = 1,
        .review_id = review_id,
        .created_at = "2026-08-29T00:00:00Z",
        .target = target,
        .producer = producer,
        .findings = &.{finding},
    };
    const manifest: committed.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = review_id,
        .review_repository_id = repository_id,
        .target = target,
        .created_at = finding_set.created_at,
        .display = null,
        .finding_count = 1,
        .producer = producer,
        .findings_digest = committed.Sha256Digest.hash(findings_bytes),
    };
    const validations = [_]git_review.CodeAnchorValidation{.{ .validated = oid }};
    var index = try build(allocator, .{
        .expected_review_repository_id = repository_id,
        .requested_review_id = review_id,
        .projection_target = target,
        .manifest = &manifest,
        .findings_bytes = findings_bytes,
        .finding_set = &finding_set,
        .projection = &projection,
        .endpoints = &endpoints,
        .anchor_validations = &validations,
    });
    defer index.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), index.summary.mapped);
}

test "finding projection releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFindingProjectionAllocations,
        .{},
    );
}
