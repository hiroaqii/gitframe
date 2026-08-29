//! Strict committed-review Git object operations.
//!
//! The target resolver is deliberately target-only. Ahead display, local
//! committed projection, and exact blob-backed anchor reads are separate
//! operations with separate failure vocabularies.

const std = @import("std");
const builtin = @import("builtin");
const wire = @import("../committed_review.zig");
const diff_parser = @import("../diff/parser.zig");
const git_command = @import("command.zig");
const endpoint = @import("committed_review/endpoint.zig");
const root_ref = @import("committed_review/root_ref.zig");

pub const ObjectFormat = wire.ObjectFormat;
pub const ObjectId = wire.ObjectId;
pub const SourceKind = wire.SourceKind;
pub const CommittedReviewTarget = wire.CommittedReviewTarget;
pub const CodeAnchor = wire.CodeAnchor;

/// All-or-nothing stdout cap for one local non-authoritative patch projection.
pub const max_projection_bytes: usize = wire.limits.max_projection_bytes;
/// Maximum committed blob bytes admitted before anchor range selection.
pub const max_anchor_blob_bytes: usize = wire.limits.max_projection_bytes;
const stderr_capture_bytes: usize = 8 * 1024;
const oid_record_slack: usize = 2;

const strict_prefix = [_][]const u8{
    "git",
    "--no-replace-objects",
    "--no-lazy-fetch",
    "--no-optional-locks",
};

/// Borrowed caller policy for the target-only resolver. Both endpoints use the
/// closed commit-ish grammar and are pinned before merge-base calculation.
pub const TargetInput = struct {
    source_kind: SourceKind,
    base: []const u8,
    head: []const u8,
};

/// Target-resolution-only terminals. Projection, ahead, and anchor failures
/// cannot appear here, and no variant carries a partial target.
pub const TargetResolutionFailure = enum {
    invalid_repository,
    unsupported_object_format,
    base_unsupported_commitish,
    head_unsupported_commitish,
    base_unresolved,
    head_unresolved,
    base_ambiguous,
    head_ambiguous,
    base_non_commit_object,
    head_non_commit_object,
    base_object_unavailable,
    head_object_unavailable,
    no_merge_base,
    ambiguous_merge_base,
    target_graph_unavailable,
    git_command_failed,
};

/// Complete pinned target or one target-resolution-specific terminal.
pub const TargetResolutionResult = union(enum) {
    target: CommittedReviewTarget,
    failure: TargetResolutionFailure,
};

/// Display-only graph-count terminals for a previously pinned target.
pub const AheadDisplayFailure = enum {
    ahead_graph_unavailable,
    ahead_git_command_failed,
};

/// Ahead count or one operation-specific graph terminal.
pub const AheadDisplayResult = union(enum) {
    count: u64,
    failure: AheadDisplayFailure,
};

/// Local, non-authoritative materialization for one exact target.
pub const CommittedDiffProjection = struct {
    target: CommittedReviewTarget,
    /// Allocator-owned exact Git stdout bytes. The owner transfers across the
    /// process adapter unchanged and releases them with `deinit`.
    patch_bytes: []u8,

    /// Release the complete patch allocation.
    pub fn deinit(self: *CommittedDiffProjection, allocator: std.mem.Allocator) void {
        allocator.free(self.patch_bytes);
        self.* = undefined;
    }
};

/// Stable projection taxonomy: stdout overflow alone is `too_large`; every
/// other Git/process/materialization failure is `git_command_failed`.
pub const ProjectionFailure = enum {
    projection_too_large,
    projection_git_command_failed,
};

/// Complete owned projection or one projection-specific terminal.
pub const ProjectionResult = union(enum) {
    projection: CommittedDiffProjection,
    failure: ProjectionFailure,

    /// Release projection bytes when present.
    pub fn deinit(self: *ProjectionResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .projection => |*projection| projection.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .projection_git_command_failed };
    }
};

/// One exact raw-diff endpoint. Paths are allocator-owned lossless Git path
/// bytes; object identity is retained even when the mode is not blob-backed.
pub const CommittedDiffEndpoint = struct {
    path_bytes: []u8,
    object_oid: ObjectId,
    mode: [6]u8,
    is_blob: bool,

    fn deinit(self: *CommittedDiffEndpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.path_bytes);
        self.* = undefined;
    }
};

/// Exact endpoint identity for one file in the extracted patch, in patch
/// order. `status_bytes` retains Git's complete raw status token.
pub const CommittedDiffEndpointRecord = struct {
    file_ordinal: usize,
    status_bytes: []u8,
    old_mode: [6]u8,
    new_mode: [6]u8,
    before: ?CommittedDiffEndpoint,
    after: ?CommittedDiffEndpoint,

    fn deinit(self: *CommittedDiffEndpointRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.status_bytes);
        if (self.before) |*value| value.deinit(allocator);
        if (self.after) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

/// Owned raw endpoint records paired ordinal-for-ordinal with one patch.
pub const CommittedDiffEndpointSidecar = struct {
    target: CommittedReviewTarget,
    records: []CommittedDiffEndpointRecord,

    pub fn deinit(self: *CommittedDiffEndpointSidecar, allocator: std.mem.Allocator) void {
        for (self.records) |*record| record.deinit(allocator);
        allocator.free(self.records);
        self.* = undefined;
    }

    /// Recheck the complete public value before a pure projection builder
    /// trusts its ordinal and endpoint framing.
    pub fn validFor(self: *const CommittedDiffEndpointSidecar, target: CommittedReviewTarget, file_count: usize) bool {
        if (!self.target.eql(&target) or self.records.len != file_count) return false;
        for (self.records, 0..) |record, ordinal| {
            if (record.file_ordinal != ordinal or !validRawStatus(record.status_bytes)) return false;
            if (!validRawEndpointShape(record.status_bytes[0], record.before != null, record.after != null)) return false;
            if (!validRawMode(&record.old_mode) or !validRawMode(&record.new_mode) or
                rawModeAbsent(&record.old_mode) != (record.before == null) or
                rawModeAbsent(&record.new_mode) != (record.after == null)) return false;
            if (record.before) |value| if (!validCommittedDiffEndpoint(value, target.object_format) or
                !std.mem.eql(u8, &value.mode, &record.old_mode)) return false;
            if (record.after) |value| if (!validCommittedDiffEndpoint(value, target.object_format) or
                !std.mem.eql(u8, &value.mode, &record.new_mode)) return false;
        }
        return true;
    }
};

/// One-command source for exact Finding projection. The patch shape remains
/// the established public projection value; the sidecar supplies authority
/// that patch presentation paths cannot provide.
pub const CommittedFindingProjectionSource = struct {
    projection: CommittedDiffProjection,
    endpoints: CommittedDiffEndpointSidecar,

    pub fn deinit(self: *CommittedFindingProjectionSource, allocator: std.mem.Allocator) void {
        self.endpoints.deinit(allocator);
        self.projection.deinit(allocator);
        self.* = undefined;
    }
};

pub const FindingProjectionSourceResult = union(enum) {
    source: CommittedFindingProjectionSource,
    failure: ProjectionFailure,

    pub fn deinit(self: *FindingProjectionSourceResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .source => |*source| source.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .projection_git_command_failed };
    }
};

/// Provisional availability for one exact target. Missing is not a Git
/// process failure and never triggers ref resolution or fetch.
pub const TargetAvailability = enum { available, missing };

pub const AvailabilityFailure = enum {
    invalid_repository,
    unsupported_object_format,
    invalid_target,
    object_format_drift,
    git_command_failed,
};

pub const AvailabilityBatchResult = union(enum) {
    available: []TargetAvailability,
    failure: AvailabilityFailure,

    pub fn deinit(self: *AvailabilityBatchResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .available => |values| allocator.free(values),
            .failure => {},
        }
        self.* = .{ .failure = .git_command_failed };
    }
};

pub const AvailabilityResult = union(enum) {
    availability: TargetAvailability,
    failure: AvailabilityFailure,
};

/// Exact committed-blob anchor terminals, deliberately separate from target
/// and projection failure vocabularies.
pub const CodeAnchorFailure = enum {
    invalid_anchor,
    path_not_found,
    path_not_blob,
    blob_object_unavailable,
    blob_too_large,
    binary_blob,
    range_out_of_bounds,
    content_digest_mismatch,
    anchor_git_command_failed,
};

/// Blob identity and exact selected preimage for a validated `CodeAnchor`.
pub const ResolvedCodeAnchor = struct {
    blob_oid: ObjectId,
    /// Allocator-owned exact committed bytes whose SHA-256 equals the anchor's
    /// `content_digest`; release them with `deinit`.
    selected_bytes: []u8,

    /// Release the selected-byte allocation.
    pub fn deinit(self: *ResolvedCodeAnchor, allocator: std.mem.Allocator) void {
        allocator.free(self.selected_bytes);
        self.* = undefined;
    }
};

/// Complete owned anchor read or one anchor-specific terminal.
pub const CodeAnchorResolution = union(enum) {
    resolved: ResolvedCodeAnchor,
    failure: CodeAnchorFailure,

    /// Release selected bytes when the anchor resolved.
    pub fn deinit(self: *CodeAnchorResolution, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .resolved => |*resolved| resolved.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .anchor_git_command_failed };
    }
};

/// Ordered, non-owning result of validating one anchor. Exact selected bytes
/// are intentionally not retained by the batch operation.
pub const CodeAnchorValidation = union(enum) {
    validated: ObjectId,
    failure: CodeAnchorFailure,
};

const EndpointSide = enum { base, head };

const EndpointFailure = enum {
    unsupported_commitish,
    unresolved,
    ambiguous,
    non_commit_object,
    object_unavailable,
    git_command_failed,
};

const EndpointResult = union(enum) {
    oid: ObjectId,
    failure: EndpointFailure,
};

const CandidateSource = enum {
    object,
    named,
};

const Candidate = struct {
    oid: ObjectId,
    source: CandidateSource,
};

const CandidateSet = struct {
    items: [9]Candidate = undefined,
    len: usize = 0,

    fn append(self: *CandidateSet, candidate: Candidate) bool {
        if (self.len == self.items.len) return false;
        self.items[self.len] = candidate;
        self.len += 1;
        return true;
    }
};

/// Pin base, head, and their exact-one best merge base, then stop. No ahead,
/// diff, tree, or blob materialization occurs in this operation.
pub fn resolveTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    input: TargetInput,
) std.mem.Allocator.Error!TargetResolutionResult {
    return resolveTargetWithHooks(allocator, io, context, input, null);
}

const TargetResolutionTestHooks = struct {
    after_endpoints_context: ?*anyopaque = null,
    after_endpoints: ?*const fn (*anyopaque, std.Io, std.Io.Dir) anyerror!void = null,
};

fn resolveTargetWithHooks(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    input: TargetInput,
    hooks: ?*const TargetResolutionTestHooks,
) std.mem.Allocator.Error!TargetResolutionResult {
    const parsed_base = endpoint.parse(input.base) catch
        return .{ .failure = .base_unsupported_commitish };
    const parsed_head = endpoint.parse(input.head) catch
        return .{ .failure = .head_unsupported_commitish };

    const format_result = try readObjectFormat(allocator, io, context);
    const format = switch (format_result) {
        .format => |value| value,
        .invalid_repository => return .{ .failure = .invalid_repository },
        .unsupported => return .{ .failure = .unsupported_object_format },
        .failed => return .{ .failure = .git_command_failed },
    };

    const base_result = try resolveEndpoint(allocator, io, context, format, parsed_base);
    const base_oid = switch (base_result) {
        .oid => |oid| oid,
        .failure => |failure| return .{ .failure = endpointFailure(.base, failure) },
    };
    const head_result = try resolveEndpoint(allocator, io, context, format, parsed_head);
    const head_oid = switch (head_result) {
        .oid => |oid| oid,
        .failure => |failure| return .{ .failure = endpointFailure(.head, failure) },
    };
    if (hooks) |active| {
        if (active.after_endpoints) |run| {
            const hook_context = active.after_endpoints_context orelse
                return .{ .failure = .git_command_failed };
            run(hook_context, io, context.cwd) catch
                return .{ .failure = .git_command_failed };
        }
    }

    const merge_result = try resolveMergeBase(allocator, io, context, format, base_oid, head_oid);
    const diff_base_oid = switch (merge_result) {
        .oid => |oid| oid,
        .no_merge_base => return .{ .failure = .no_merge_base },
        .ambiguous => return .{ .failure = .ambiguous_merge_base },
        .graph_unavailable => return .{ .failure = .target_graph_unavailable },
        .failed => return .{ .failure = .git_command_failed },
    };
    const target: CommittedReviewTarget = .{
        .object_format = format,
        .source_kind = input.source_kind,
        .base_oid = base_oid,
        .head_oid = head_oid,
        .diff_base_oid = diff_base_oid,
    };
    target.validate() catch return .{ .failure = .git_command_failed };
    return .{ .target = target };
}

/// Compute a display-only ahead count from the already pinned target graph.
pub fn computeAheadDisplay(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: CommittedReviewTarget,
) std.mem.Allocator.Error!AheadDisplayResult {
    target.validate() catch return .{ .failure = .ahead_git_command_failed };
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{
        target.diff_base_oid.slice(),
        target.head_oid.slice(),
    });
    defer allocator.free(range);
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "rev-list",       "--count",        range,
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(32),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .{ .failure = .ahead_git_command_failed },
    };
    if (!termExited(completed.term, 0)) return .{ .failure = .ahead_graph_unavailable };
    const text = singleLfLine(completed.stdout) orelse return .{ .failure = .ahead_git_command_failed };
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return .{ .failure = .ahead_git_command_failed };
    var count: u64 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return .{ .failure = .ahead_git_command_failed };
        count = std.math.mul(u64, count, 10) catch return .{ .failure = .ahead_git_command_failed };
        count = std.math.add(u64, count, byte - '0') catch return .{ .failure = .ahead_git_command_failed };
    }
    return .{ .count = count };
}

/// Materialize the shared checkout-independent committed patch. Versioned
/// attributes come from `target.head_oid`; worktree/index content is excluded.
pub fn materializeCommittedProjection(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: CommittedReviewTarget,
) std.mem.Allocator.Error!ProjectionResult {
    return materializeCommittedProjectionWithGit(allocator, io, context, target, strict_prefix[0]);
}

/// Materialize one patch plus its exact raw endpoint identities with one Git
/// command. There is no retry or path-derived fallback.
pub fn materializeCommittedFindingProjectionSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: CommittedReviewTarget,
) std.mem.Allocator.Error!FindingProjectionSourceResult {
    return materializeCommittedFindingProjectionSourceWithGit(
        allocator,
        io,
        context,
        target,
        strict_prefix[0],
    );
}

/// Probe up to 512 targets with one no-lazy-fetch `cat-file` transaction.
/// Any framing/type/process failure discards every partial classification.
pub fn checkTargetsAvailability(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    targets: []const CommittedReviewTarget,
) std.mem.Allocator.Error!AvailabilityBatchResult {
    if (targets.len > 512) return .{ .failure = .invalid_target };
    const format_result = try readObjectFormat(allocator, io, context);
    const format = switch (format_result) {
        .format => |value| value,
        .invalid_repository => return .{ .failure = .invalid_repository },
        .unsupported => return .{ .failure = .unsupported_object_format },
        .failed => return .{ .failure = .git_command_failed },
    };
    for (targets) |target| {
        target.validate() catch return .{ .failure = .invalid_target };
        if (target.object_format != format) return .{ .failure = .object_format_drift };
    }
    if (targets.len == 0) return .{ .available = try allocator.alloc(TargetAvailability, 0) };

    var stdin: std.ArrayList(u8) = .empty;
    defer stdin.deinit(allocator);
    for (targets) |target| {
        for ([_]*const ObjectId{ &target.base_oid, &target.head_oid, &target.diff_base_oid }) |oid| {
            try stdin.appendSlice(allocator, oid.slice());
            try stdin.append(allocator, '\n');
        }
    }
    if (stdin.items.len > 100 * 1024) return .{ .failure = .invalid_target };

    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1],                            strict_prefix[2], strict_prefix[3],
        "cat-file",       "--batch-check=%(objectname) %(objecttype)",
    };
    var command = try git_command.runWithStdinBounded(allocator, io, context, .{
        .argv = &argv,
        .stdin = stdin.items,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer command.deinit(allocator);
    const completed = switch (command) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .{ .failure = .git_command_failed },
    };
    if (!termExited(completed.term, 0)) return .{ .failure = .git_command_failed };
    const statuses = parseAvailabilityRecords(allocator, targets, completed.stdout) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .git_command_failed };
    };
    return .{ .available = statuses };
}

pub fn checkTargetAvailability(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: CommittedReviewTarget,
) std.mem.Allocator.Error!AvailabilityResult {
    var batch = try checkTargetsAvailability(allocator, io, context, &.{target});
    defer batch.deinit(allocator);
    return switch (batch) {
        .available => |values| .{ .availability = values[0] },
        .failure => |failure| .{ .failure = failure },
    };
}

fn parseAvailabilityRecords(
    allocator: std.mem.Allocator,
    targets: []const CommittedReviewTarget,
    stdout: []const u8,
) ![]TargetAvailability {
    const statuses = try allocator.alloc(TargetAvailability, targets.len);
    errdefer allocator.free(statuses);
    @memset(statuses, .available);
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    for (targets, 0..) |target, target_index| {
        for ([_]*const ObjectId{ &target.base_oid, &target.head_oid, &target.diff_base_oid }) |oid| {
            const line = lines.next() orelse return error.InvalidAvailabilityOutput;
            const suffix = if (std.mem.endsWith(u8, line, " commit"))
                " commit"
            else if (std.mem.endsWith(u8, line, " missing"))
                " missing"
            else
                return error.InvalidAvailabilityOutput;
            const oid_text = line[0 .. line.len - suffix.len];
            if (!std.mem.eql(u8, oid_text, oid.slice())) return error.InvalidAvailabilityOutput;
            if (suffix[1] == 'm') statuses[target_index] = .missing;
        }
    }
    const terminal = lines.next() orelse return error.InvalidAvailabilityOutput;
    if (terminal.len != 0 or lines.next() != null) return error.InvalidAvailabilityOutput;
    return statuses;
}

fn materializeCommittedProjectionWithGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: CommittedReviewTarget,
    git_executable: []const u8,
) std.mem.Allocator.Error!ProjectionResult {
    const capture = try captureCommittedDiff(
        allocator,
        io,
        context,
        target,
        git_executable,
        &.{},
        max_projection_bytes,
    );
    return switch (capture) {
        .bytes => |bytes| .{ .projection = .{ .target = target, .patch_bytes = bytes } },
        .failure => |failure| .{ .failure = failure },
    };
}

fn materializeCommittedFindingProjectionSourceWithGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: CommittedReviewTarget,
    git_executable: []const u8,
) std.mem.Allocator.Error!FindingProjectionSourceResult {
    const combined_limit = std.math.mul(usize, max_projection_bytes, 2) catch unreachable;
    const capture = try captureCommittedDiff(
        allocator,
        io,
        context,
        target,
        git_executable,
        &.{ "--raw", "-z", "--no-abbrev", "--patch" },
        combined_limit,
    );
    const combined = switch (capture) {
        .bytes => |bytes| bytes,
        .failure => |failure| return .{ .failure = failure },
    };
    defer allocator.free(combined);

    return buildFindingProjectionSourceFromCombined(allocator, target, combined);
}

fn buildFindingProjectionSourceFromCombined(
    allocator: std.mem.Allocator,
    target: CommittedReviewTarget,
    combined: []const u8,
) std.mem.Allocator.Error!FindingProjectionSourceResult {
    const admitted_patch_start = switch (combinedComponentBounds(combined)) {
        .patch_start => |value| value,
        .too_large => return .{ .failure = .projection_too_large },
        .malformed => return .{ .failure = .projection_git_command_failed },
    };
    var split_optional: ?ParsedCombinedDiffSource = parseCombinedDiffSource(allocator, target, combined) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .projection_git_command_failed },
    };
    defer if (split_optional) |*split| split.endpoints.deinit(allocator);
    const split = &split_optional.?;
    if (split.patch_start != admitted_patch_start) return .{ .failure = .projection_git_command_failed };
    const patch = combined[split.patch_start..];

    var document = diff_parser.parse(allocator, patch) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .projection_git_command_failed },
    };
    defer document.deinit(allocator);
    if (document.files.len != split.endpoints.records.len)
        return .{ .failure = .projection_git_command_failed };

    const patch_bytes = try allocator.dupe(u8, patch);
    const endpoints = split.endpoints;
    split_optional = null;
    return .{ .source = .{
        .projection = .{ .target = target, .patch_bytes = patch_bytes },
        .endpoints = endpoints,
    } };
}

const ProjectionCapture = union(enum) {
    bytes: []u8,
    failure: ProjectionFailure,
};

fn captureCommittedDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: CommittedReviewTarget,
    git_executable: []const u8,
    output_options: []const []const u8,
    stdout_limit: usize,
) std.mem.Allocator.Error!ProjectionCapture {
    target.validate() catch return .{ .failure = .projection_git_command_failed };
    const attr_source = try std.fmt.allocPrint(allocator, "--attr-source={s}", .{target.head_oid.slice()});
    defer allocator.free(attr_source);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        git_executable,
        strict_prefix[1],
        strict_prefix[2],
        strict_prefix[3],
        attr_source,
        "diff",
    });
    try argv.appendSlice(allocator, output_options);
    try argv.appendSlice(allocator, &.{
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        target.diff_base_oid.slice(),
        target.head_oid.slice(),
    });
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = argv.items,
        .stdout_limit = .limited(stdout_limit),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    switch (result) {
        .stdout_limit_exceeded => return .{ .failure = .projection_too_large },
        .stderr_limit_exceeded => return .{ .failure = .projection_git_command_failed },
        .failed => |*failure| {
            failure.deinit(allocator);
            return .{ .failure = .projection_git_command_failed };
        },
        .completed => |completed| {
            if (!termExited(completed.term, 0)) {
                completed.deinit(allocator);
                return .{ .failure = .projection_git_command_failed };
            }
            allocator.free(completed.stderr);
            return .{ .bytes = completed.stdout };
        },
    }
}

const ParsedCombinedDiffSource = struct {
    patch_start: usize,
    endpoints: CommittedDiffEndpointSidecar,
};

const CombinedComponentBounds = union(enum) { patch_start: usize, too_large, malformed };

fn combinedComponentBounds(bytes: []const u8) CombinedComponentBounds {
    if (bytes.len == 0) return .{ .patch_start = 0 };
    const boundary = std.mem.indexOf(u8, bytes, "\x00\x00") orelse return .malformed;
    const patch_start = boundary + 2;
    if (patch_start > max_projection_bytes or bytes.len - patch_start > max_projection_bytes) return .too_large;
    return .{ .patch_start = patch_start };
}

const RawDiffParseError = error{InvalidRawDiff};

fn parseCombinedDiffSource(
    allocator: std.mem.Allocator,
    target: CommittedReviewTarget,
    bytes: []const u8,
) (RawDiffParseError || std.mem.Allocator.Error)!ParsedCombinedDiffSource {
    if (bytes.len == 0) return .{
        .patch_start = 0,
        .endpoints = .{ .target = target, .records = try allocator.alloc(CommittedDiffEndpointRecord, 0) },
    };

    var records: std.ArrayList(CommittedDiffEndpointRecord) = .empty;
    errdefer {
        for (records.items) |*record| record.deinit(allocator);
        records.deinit(allocator);
    }
    var cursor: usize = 0;
    while (true) {
        if (cursor >= bytes.len) return error.InvalidRawDiff;
        if (bytes[cursor] == 0) {
            cursor += 1;
            break;
        }
        if (bytes[cursor] != ':') return error.InvalidRawDiff;
        const header_end = std.mem.indexOfScalarPos(u8, bytes, cursor, 0) orelse return error.InvalidRawDiff;
        const header = bytes[cursor + 1 .. header_end];
        var fields = std.mem.splitScalar(u8, header, ' ');
        const old_mode_text = fields.next() orelse return error.InvalidRawDiff;
        const new_mode_text = fields.next() orelse return error.InvalidRawDiff;
        const old_oid_text = fields.next() orelse return error.InvalidRawDiff;
        const new_oid_text = fields.next() orelse return error.InvalidRawDiff;
        const status = fields.next() orelse return error.InvalidRawDiff;
        if (fields.next() != null or !validRawMode(old_mode_text) or !validRawMode(new_mode_text) or
            !validRawStatus(status)) return error.InvalidRawDiff;
        const old_oid = try parseRawOid(target.object_format, old_oid_text);
        const new_oid = try parseRawOid(target.object_format, new_oid_text);
        const old_absent = rawModeAbsent(old_mode_text);
        const new_absent = rawModeAbsent(new_mode_text);
        if ((old_oid == null) != old_absent or (new_oid == null) != new_absent)
            return error.InvalidRawDiff;

        cursor = header_end + 1;
        const first_path_end = std.mem.indexOfScalarPos(u8, bytes, cursor, 0) orelse return error.InvalidRawDiff;
        if (first_path_end == cursor or first_path_end - cursor > wire.limits.max_raw_path_bytes)
            return error.InvalidRawDiff;
        const first_path = bytes[cursor..first_path_end];
        cursor = first_path_end + 1;
        var second_path: ?[]const u8 = null;
        if (status[0] == 'R' or status[0] == 'C') {
            const second_path_end = std.mem.indexOfScalarPos(u8, bytes, cursor, 0) orelse return error.InvalidRawDiff;
            if (second_path_end == cursor or second_path_end - cursor > wire.limits.max_raw_path_bytes)
                return error.InvalidRawDiff;
            second_path = bytes[cursor..second_path_end];
            cursor = second_path_end + 1;
        }

        const before_path = first_path;
        const after_path = second_path orelse first_path;
        var before = if (old_oid) |oid|
            try makeRawEndpoint(allocator, before_path, oid, old_mode_text)
        else
            null;
        errdefer if (before) |*value| value.deinit(allocator);
        var after = if (new_oid) |oid|
            try makeRawEndpoint(allocator, after_path, oid, new_mode_text)
        else
            null;
        errdefer if (after) |*value| value.deinit(allocator);
        if (!validRawEndpointShape(status[0], before != null, after != null)) return error.InvalidRawDiff;
        var status_bytes: ?[]u8 = try allocator.dupe(u8, status);
        errdefer if (status_bytes) |owned| allocator.free(owned);
        try records.append(allocator, .{
            .file_ordinal = records.items.len,
            .status_bytes = status_bytes.?,
            .old_mode = rawModeValue(old_mode_text),
            .new_mode = rawModeValue(new_mode_text),
            .before = before,
            .after = after,
        });
        before = null;
        after = null;
        status_bytes = null;
    }
    if (records.items.len == 0 or cursor > bytes.len) return error.InvalidRawDiff;
    return .{
        .patch_start = cursor,
        .endpoints = .{ .target = target, .records = try records.toOwnedSlice(allocator) },
    };
}

fn validRawMode(text: []const u8) bool {
    if (text.len != 6) return false;
    for (text) |byte| if (byte < '0' or byte > '7') return false;
    return rawModeAbsent(text) or std.mem.eql(u8, text, "100644") or
        std.mem.eql(u8, text, "100755") or std.mem.eql(u8, text, "120000") or
        std.mem.eql(u8, text, "160000") or std.mem.eql(u8, text, "040000");
}

fn rawModeAbsent(text: []const u8) bool {
    return std.mem.eql(u8, text, "000000");
}

fn rawModeIsBlob(text: []const u8) bool {
    return std.mem.eql(u8, text, "100644") or std.mem.eql(u8, text, "100755") or
        std.mem.eql(u8, text, "120000");
}

fn rawModeValue(text: []const u8) [6]u8 {
    var value: [6]u8 = undefined;
    @memcpy(&value, text);
    return value;
}

fn validCommittedDiffEndpoint(endpoint_value: CommittedDiffEndpoint, format: ObjectFormat) bool {
    return endpoint_value.path_bytes.len != 0 and
        endpoint_value.path_bytes.len <= wire.limits.max_raw_path_bytes and
        std.mem.indexOfScalar(u8, endpoint_value.path_bytes, 0) == null and
        endpoint_value.object_oid.validFor(format) and validRawMode(&endpoint_value.mode) and
        !rawModeAbsent(&endpoint_value.mode) and endpoint_value.is_blob == rawModeIsBlob(&endpoint_value.mode);
}

fn validRawStatus(status: []const u8) bool {
    if (status.len == 1) return switch (status[0]) {
        'A', 'D', 'M', 'T' => true,
        else => false,
    };
    if (status.len != 4 or (status[0] != 'R' and status[0] != 'C')) return false;
    for (status[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn validRawEndpointShape(status: u8, has_before: bool, has_after: bool) bool {
    return switch (status) {
        'A' => !has_before and has_after,
        'D' => has_before and !has_after,
        'M', 'T', 'R', 'C' => has_before and has_after,
        else => false,
    };
}

fn parseRawOid(format: ObjectFormat, text: []const u8) RawDiffParseError!?ObjectId {
    if (text.len != format.oidHexLength()) return error.InvalidRawDiff;
    var all_zero = true;
    for (text) |byte| if (byte != '0') {
        all_zero = false;
        break;
    };
    if (all_zero) return null;
    return ObjectId.parse(format, text) catch error.InvalidRawDiff;
}

fn makeRawEndpoint(
    allocator: std.mem.Allocator,
    path: []const u8,
    oid: ObjectId,
    mode_text: []const u8,
) std.mem.Allocator.Error!CommittedDiffEndpoint {
    return .{
        .path_bytes = try allocator.dupe(u8, path),
        .object_oid = oid,
        .mode = rawModeValue(mode_text),
        .is_blob = rawModeIsBlob(mode_text),
    };
}

/// Validate an ordered set of anchors with operation-local path and blob
/// deduplication. Returned entries retain no blob or selected-range bytes.
pub fn validateCodeAnchors(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: CommittedReviewTarget,
    anchors: []const CodeAnchor,
) std.mem.Allocator.Error![]CodeAnchorValidation {
    const batch = try resolveCodeAnchorsInternal(
        allocator,
        io,
        context,
        target,
        anchors,
        null,
        strict_prefix[0],
    );
    std.debug.assert(batch.selected_bytes == null);
    return batch.validations;
}

/// Read and validate one anchor against exact committed blob bytes selected by
/// target side, raw path, 1-based inclusive range, and content digest.
pub fn resolveCodeAnchor(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: CommittedReviewTarget,
    anchor: CodeAnchor,
) std.mem.Allocator.Error!CodeAnchorResolution {
    const batch = try resolveCodeAnchorsInternal(
        allocator,
        io,
        context,
        target,
        &.{anchor},
        0,
        strict_prefix[0],
    );
    defer allocator.free(batch.validations);
    return switch (batch.validations[0]) {
        .failure => |failure| .{ .failure = failure },
        .validated => |blob_oid| .{ .resolved = .{
            .blob_oid = blob_oid,
            .selected_bytes = batch.selected_bytes.?,
        } },
    };
}

const AnchorBatchResolution = struct {
    validations: []CodeAnchorValidation,
    selected_bytes: ?[]u8,
};

const AnchorPathResolution = union(enum) {
    pending,
    blob: ObjectId,
    failure: CodeAnchorFailure,
};

const AnchorPathGroup = struct {
    representative: usize,
    resolution: AnchorPathResolution = .pending,
};

fn resolveCodeAnchorsInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: CommittedReviewTarget,
    anchors: []const CodeAnchor,
    capture_anchor_index: ?usize,
    git_executable: []const u8,
) std.mem.Allocator.Error!AnchorBatchResolution {
    std.debug.assert(capture_anchor_index == null or capture_anchor_index.? < anchors.len);
    const validations = try allocator.alloc(CodeAnchorValidation, anchors.len);
    errdefer allocator.free(validations);
    @memset(validations, .{ .failure = .anchor_git_command_failed });
    target.validate() catch {
        return .{ .validations = validations, .selected_bytes = null };
    };
    if (anchors.len == 0) return .{ .validations = validations, .selected_bytes = null };

    const group_for_anchor = try allocator.alloc(?usize, anchors.len);
    defer allocator.free(group_for_anchor);
    @memset(group_for_anchor, null);
    var groups: std.ArrayList(AnchorPathGroup) = .empty;
    defer groups.deinit(allocator);

    for (anchors, 0..) |anchor, anchor_index| {
        if (!validCodeAnchor(anchor)) {
            validations[anchor_index] = .{ .failure = .invalid_anchor };
            continue;
        }
        const group_index = findAnchorPathGroup(groups.items, anchors, anchor) orelse group: {
            try groups.append(allocator, .{ .representative = anchor_index });
            break :group groups.items.len - 1;
        };
        group_for_anchor[anchor_index] = group_index;
    }

    var before_tree: ?BatchResult = null;
    var after_tree: ?BatchResult = null;
    for (groups.items) |group| {
        switch (anchors[group.representative].side) {
            .before => if (before_tree == null) {
                before_tree = try batchCheckWithGit(
                    allocator,
                    io,
                    context,
                    target.object_format,
                    target.diff_base_oid.slice(),
                    git_executable,
                );
            },
            .after => if (after_tree == null) {
                after_tree = try batchCheckWithGit(
                    allocator,
                    io,
                    context,
                    target.object_format,
                    target.head_oid.slice(),
                    git_executable,
                );
            },
        }
    }

    for (groups.items) |*group| {
        const anchor = anchors[group.representative];
        const tree_oid = switch (anchor.side) {
            .before => target.diff_base_oid,
            .after => target.head_oid,
        };
        const tree_result = switch (anchor.side) {
            .before => before_tree.?,
            .after => after_tree.?,
        };
        switch (tree_result) {
            .missing => {
                group.resolution = .{ .failure = .blob_object_unavailable };
                continue;
            },
            .failed => {
                group.resolution = .{ .failure = .anchor_git_command_failed };
                continue;
            },
            .object => {},
        }
        group.resolution = switch (try lookupAnchorPathWithGit(
            allocator,
            io,
            context,
            target.object_format,
            tree_oid,
            anchor.path_bytes,
            git_executable,
        )) {
            .blob => |oid| .{ .blob = oid },
            .not_found => .{ .failure = .path_not_found },
            .not_blob => .{ .failure = .path_not_blob },
            .failed => .{ .failure = .anchor_git_command_failed },
        };
    }

    for (anchors, 0..) |_, anchor_index| {
        const group_index = group_for_anchor[anchor_index] orelse continue;
        switch (groups.items[group_index].resolution) {
            .failure => |failure| validations[anchor_index] = .{ .failure = failure },
            .pending, .blob => {},
        }
    }

    var blob_oids: std.ArrayList(ObjectId) = .empty;
    defer blob_oids.deinit(allocator);
    for (groups.items) |group| {
        const oid = switch (group.resolution) {
            .blob => |value| value,
            .pending, .failure => continue,
        };
        var seen = false;
        for (blob_oids.items) |*existing| {
            if (existing.eql(&oid)) {
                seen = true;
                break;
            }
        }
        if (!seen) try blob_oids.append(allocator, oid);
    }

    var selected_bytes: ?[]u8 = null;
    errdefer if (selected_bytes) |bytes| allocator.free(bytes);
    for (blob_oids.items) |blob_oid| {
        const checked = try batchCheckWithGit(
            allocator,
            io,
            context,
            target.object_format,
            blob_oid.slice(),
            git_executable,
        );
        const check_failure: ?CodeAnchorFailure = switch (checked) {
            .missing => .blob_object_unavailable,
            .failed => .anchor_git_command_failed,
            .object => |object| if (object.kind == .blob) null else .path_not_blob,
        };
        if (check_failure) |failure| {
            assignBlobFailure(validations, anchors, group_for_anchor, groups.items, blob_oid, failure);
            continue;
        }

        var blob_result = try readAnchorBlobWithGit(allocator, io, context, blob_oid, git_executable);
        defer blob_result.deinit(allocator);
        const blob = switch (blob_result) {
            .bytes => |bytes| bytes,
            .failure => |failure| {
                assignBlobFailure(validations, anchors, group_for_anchor, groups.items, blob_oid, failure);
                continue;
            },
        };
        for (anchors, 0..) |anchor, anchor_index| {
            const group_index = group_for_anchor[anchor_index] orelse continue;
            const group_oid = switch (groups.items[group_index].resolution) {
                .blob => |value| value,
                .pending, .failure => continue,
            };
            if (!group_oid.eql(&blob_oid)) continue;
            switch (validateAnchorBlobBytes(blob, anchor)) {
                .failure => |failure| validations[anchor_index] = .{ .failure = failure },
                .selected => |selected| {
                    validations[anchor_index] = .{ .validated = blob_oid };
                    if (capture_anchor_index != null and capture_anchor_index.? == anchor_index)
                        selected_bytes = try allocator.dupe(u8, selected);
                },
            }
        }
    }
    return .{ .validations = validations, .selected_bytes = selected_bytes };
}

fn validCodeAnchor(anchor: CodeAnchor) bool {
    return anchor.path_bytes.len != 0 and anchor.path_bytes.len <= wire.limits.max_raw_path_bytes and
        std.mem.indexOfScalar(u8, anchor.path_bytes, 0) == null and
        anchor.start_line != 0 and anchor.end_line >= anchor.start_line;
}

fn findAnchorPathGroup(
    groups: []const AnchorPathGroup,
    anchors: []const CodeAnchor,
    anchor: CodeAnchor,
) ?usize {
    for (groups, 0..) |group, index| {
        const existing = anchors[group.representative];
        if (existing.side == anchor.side and std.mem.eql(u8, existing.path_bytes, anchor.path_bytes)) return index;
    }
    return null;
}

const AnchorPathLookup = union(enum) { blob: ObjectId, not_found, not_blob, failed };

fn lookupAnchorPathWithGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    tree_oid: ObjectId,
    path: []const u8,
    git_executable: []const u8,
) std.mem.Allocator.Error!AnchorPathLookup {
    const tree_argv = [_][]const u8{
        git_executable,        strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "--literal-pathspecs", "ls-tree",        "-rz",            "--full-tree",
        tree_oid.slice(),      "--",             path,
    };
    var tree_result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &tree_argv,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer tree_result.deinit(allocator);
    const tree_completed = switch (tree_result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    if (!termExited(tree_completed.term, 0)) return .failed;
    if (tree_completed.stdout.len == 0) return .not_found;
    const blob_oid = parseLsTreeRecord(format, tree_completed.stdout, path) orelse return .not_blob;
    return .{ .blob = blob_oid };
}

const AnchorBlobRead = union(enum) {
    bytes: []u8,
    failure: CodeAnchorFailure,

    fn deinit(self: *AnchorBlobRead, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .bytes => |bytes| allocator.free(bytes),
            .failure => {},
        }
        self.* = .{ .failure = .anchor_git_command_failed };
    }
};

fn readAnchorBlobWithGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    blob_oid: ObjectId,
    git_executable: []const u8,
) std.mem.Allocator.Error!AnchorBlobRead {
    const blob_argv = [_][]const u8{
        git_executable, strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "cat-file",     "blob",           blob_oid.slice(),
    };
    var blob_result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &blob_argv,
        .stdout_limit = .limited(max_anchor_blob_bytes),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    switch (blob_result) {
        .stdout_limit_exceeded => return .{ .failure = .blob_too_large },
        .stderr_limit_exceeded => return .{ .failure = .anchor_git_command_failed },
        .failed => |*failure| {
            failure.deinit(allocator);
            return .{ .failure = .anchor_git_command_failed };
        },
        .completed => |completed| {
            if (!termExited(completed.term, 0)) {
                completed.deinit(allocator);
                return .{ .failure = .anchor_git_command_failed };
            }
            allocator.free(completed.stderr);
            return .{ .bytes = completed.stdout };
        },
    }
}

const AnchorBlobValidation = union(enum) {
    selected: []const u8,
    failure: CodeAnchorFailure,
};

fn validateAnchorBlobBytes(bytes: []const u8, anchor: CodeAnchor) AnchorBlobValidation {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return .{ .failure = .binary_blob };
    const selected = selectLines(bytes, anchor.start_line, anchor.end_line) orelse
        return .{ .failure = .range_out_of_bounds };
    const digest = wire.Sha256Digest.hash(selected);
    if (!digest.eql(anchor.content_digest)) return .{ .failure = .content_digest_mismatch };
    return .{ .selected = selected };
}

fn assignBlobFailure(
    validations: []CodeAnchorValidation,
    anchors: []const CodeAnchor,
    group_for_anchor: []const ?usize,
    groups: []const AnchorPathGroup,
    blob_oid: ObjectId,
    failure: CodeAnchorFailure,
) void {
    for (anchors, 0..) |_, anchor_index| {
        const group_index = group_for_anchor[anchor_index] orelse continue;
        const group_oid = switch (groups[group_index].resolution) {
            .blob => |value| value,
            .pending, .failure => continue,
        };
        if (group_oid.eql(&blob_oid)) validations[anchor_index] = .{ .failure = failure };
    }
}

const ObjectFormatResult = union(enum) {
    format: ObjectFormat,
    invalid_repository,
    unsupported,
    failed,
};

fn readObjectFormat(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) std.mem.Allocator.Error!ObjectFormatResult {
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1],       strict_prefix[2], strict_prefix[3],
        "rev-parse",      "--show-object-format",
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(16),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    if (!termExited(completed.term, 0)) {
        return if (try strictPrefixSupported(allocator, io, context)) .invalid_repository else .failed;
    }
    const text = singleLfLine(completed.stdout) orelse return .failed;
    if (std.mem.eql(u8, text, "sha1")) return .{ .format = .sha1 };
    if (std.mem.eql(u8, text, "sha256")) return .{ .format = .sha256 };
    return .unsupported;
}

fn strictPrefixSupported(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) std.mem.Allocator.Error!bool {
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3], "--version",
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    return switch (result) {
        .completed => |value| termExited(value.term, 0),
        else => false,
    };
}

fn resolveEndpoint(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    parsed: endpoint.Parsed,
) std.mem.Allocator.Error!EndpointResult {
    var candidates: CandidateSet = .{};
    if (parsed.baseIsHex() and parsed.base.len >= 4 and parsed.base.len <= format.oidHexLength()) {
        switch (try probeObjectCandidates(allocator, io, context, format, parsed.base, &candidates)) {
            .ok => {},
            .ambiguous => return .{ .failure = .ambiguous },
            .unresolved, .failed => return .{ .failure = .git_command_failed },
        }
    }

    const ref_validity = try validateRefAtom(allocator, io, context, parsed.base);
    switch (ref_validity) {
        .failed => return .{ .failure = .git_command_failed },
        .invalid => {},
        .valid_one_level => {
            switch (try probeRootCandidate(allocator, io, context, format, parsed.base, &candidates)) {
                .ok => {},
                .ambiguous => return .{ .failure = .ambiguous },
                .unresolved => return .{ .failure = .unresolved },
                .failed => return .{ .failure = .git_command_failed },
            }
        },
        .valid_slash => {},
    }
    if (ref_validity != .invalid) {
        switch (try probeNamespaceCandidates(allocator, io, context, format, parsed.base, &candidates)) {
            .ok => {},
            .ambiguous => return .{ .failure = .ambiguous },
            .unresolved => return .{ .failure = .unresolved },
            .failed => return .{ .failure = .git_command_failed },
        }
    }

    if (candidates.len == 0) return .{ .failure = .unresolved };
    if (candidates.len != 1) return .{ .failure = .ambiguous };
    const selected = candidates.items[0];
    if (selected.source == .named and parsed.suffix_text.len != 0) {
        switch (try batchCheck(allocator, io, context, format, selected.oid.slice())) {
            .missing => return .{ .failure = .object_unavailable },
            .failed => return .{ .failure = .git_command_failed },
            .object => {},
        }
    }
    const expression = try std.fmt.allocPrint(allocator, "{s}{s}", .{ selected.oid.slice(), parsed.suffix_text });
    defer allocator.free(expression);
    return validateCommitExpression(allocator, io, context, format, expression, selected.source, parsed.suffix_text.len == 0);
}

const ProbeStatus = enum { ok, ambiguous, unresolved, failed };

fn probeObjectCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    base: []const u8,
    candidates: *CandidateSet,
) std.mem.Allocator.Error!ProbeStatus {
    const option = try std.fmt.allocPrint(allocator, "--disambiguate={s}", .{base});
    defer allocator.free(option);
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "rev-parse",      option,
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited((format.oidHexLength() + 1) * 2),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .stdout_limit_exceeded => return .ambiguous,
        .stderr_limit_exceeded, .failed => return .failed,
        .completed => |value| value,
    };
    if (!termExited(completed.term, 0)) return .failed;
    var records: [2]ObjectId = undefined;
    const count = parseOidRecords(format, completed.stdout, &records) orelse return .failed;
    if (count > 1) return .ambiguous;
    if (count == 1 and !candidates.append(.{ .oid = records[0], .source = .object })) return .ambiguous;
    return .ok;
}

const RefValidity = enum { invalid, valid_one_level, valid_slash, failed };

fn validateRefAtom(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    atom: []const u8,
) std.mem.Allocator.Error!RefValidity {
    const one_level = std.mem.indexOfScalar(u8, atom, '/') == null;
    const argv_one = [_][]const u8{
        strict_prefix[0],   strict_prefix[1],   strict_prefix[2], strict_prefix[3],
        "check-ref-format", "--allow-onelevel", atom,
    };
    const argv_slash = [_][]const u8{
        strict_prefix[0],   strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "check-ref-format", atom,
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = if (one_level) &argv_one else &argv_slash,
        .stdout_limit = .limited(0),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    return switch (completed.term) {
        .exited => |code| switch (code) {
            0 => if (one_level) .valid_one_level else .valid_slash,
            1 => .invalid,
            else => .failed,
        },
        else => .failed,
    };
}

fn probeRootCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    atom: []const u8,
    candidates: *CandidateSet,
) std.mem.Allocator.Error!ProbeStatus {
    std.debug.assert(std.mem.indexOfScalar(u8, atom, '/') == null);
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1],         strict_prefix[2], strict_prefix[3],
        "rev-parse",      "--path-format=absolute", "--git-path",     atom,
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(endpoint.max_input_bytes + 1),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    if (!termExited(completed.term, 0)) return .failed;
    const path = singleLfLine(completed.stdout) orelse return .failed;
    var probe = try root_ref.probe(allocator, io, path);
    defer probe.deinit(allocator);
    switch (probe) {
        .absent => return .ok,
        .ambiguous => return .ambiguous,
        .failed => return .failed,
        .candidates => |*list| {
            if (list.len != 1) return .ambiguous;
            switch (list.items[0]) {
                .oid => |text| {
                    const oid = ObjectId.parse(format, text) catch return .failed;
                    if (!candidates.append(.{ .oid = oid, .source = .named })) return .ambiguous;
                },
                .symbolic_ref => |full_ref| {
                    switch (try validateRefAtom(allocator, io, context, full_ref)) {
                        .valid_slash => {},
                        .invalid, .valid_one_level, .failed => return .failed,
                    }
                    const ref_result = try probeFullRef(allocator, io, context, format, full_ref);
                    switch (ref_result) {
                        .absent, .race_unresolved => return .unresolved,
                        .failed => return .failed,
                        .oid => |oid| if (!candidates.append(.{ .oid = oid, .source = .named })) return .ambiguous,
                    }
                },
            }
        },
    }
    return .ok;
}

fn probeNamespaceCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    atom: []const u8,
    candidates: *CandidateSet,
) std.mem.Allocator.Error!ProbeStatus {
    if (std.mem.startsWith(u8, atom, "refs/")) {
        return appendRefCandidate(allocator, io, context, format, atom, candidates);
    }
    var refs: [5][]u8 = undefined;
    var refs_len: usize = 0;
    defer for (refs[0..refs_len]) |value| allocator.free(value);
    refs[refs_len] = try std.fmt.allocPrint(allocator, "refs/{s}", .{atom});
    refs_len += 1;
    refs[refs_len] = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{atom});
    refs_len += 1;
    refs[refs_len] = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{atom});
    refs_len += 1;
    refs[refs_len] = try std.fmt.allocPrint(allocator, "refs/remotes/{s}", .{atom});
    refs_len += 1;
    refs[refs_len] = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/HEAD", .{atom});
    refs_len += 1;
    for (refs[0..refs_len]) |full_ref| {
        const status = try appendRefCandidate(allocator, io, context, format, full_ref, candidates);
        if (status != .ok) return status;
    }
    return .ok;
}

fn appendRefCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    full_ref: []const u8,
    candidates: *CandidateSet,
) std.mem.Allocator.Error!ProbeStatus {
    return switch (try probeFullRef(allocator, io, context, format, full_ref)) {
        .absent => .ok,
        .race_unresolved => .unresolved,
        .failed => .failed,
        .oid => |oid| if (candidates.append(.{ .oid = oid, .source = .named })) .ok else .ambiguous,
    };
}

const RefProbeResult = union(enum) {
    absent,
    race_unresolved,
    oid: ObjectId,
    failed,
};

fn probeFullRef(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    full_ref: []const u8,
) std.mem.Allocator.Error!RefProbeResult {
    const exists_argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "show-ref",       "--exists",       full_ref,
    };
    var exists = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &exists_argv,
        .stdout_limit = .limited(0),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer exists.deinit(allocator);
    const exists_completed = switch (exists) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    switch (exists_completed.term) {
        .exited => |code| switch (code) {
            0 => {},
            2 => return .absent,
            else => return .failed,
        },
        else => return .failed,
    }

    const hash_argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "show-ref",       "--verify",       "--hash",         full_ref,
    };
    var hash = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &hash_argv,
        .stdout_limit = .limited(format.oidHexLength() + oid_record_slack),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer hash.deinit(allocator);
    const hash_completed = switch (hash) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    if (!termExited(hash_completed.term, 0)) return .race_unresolved;
    const oid = parseSingleOid(format, hash_completed.stdout) orelse return .failed;
    return .{ .oid = oid };
}

fn validateCommitExpression(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    expression: []const u8,
    source: CandidateSource,
    no_suffix: bool,
) std.mem.Allocator.Error!EndpointResult {
    const checked = try batchCheck(allocator, io, context, format, expression);
    switch (checked) {
        .missing => return .{ .failure = if (source == .named and no_suffix) .object_unavailable else .unresolved },
        .failed => return .{ .failure = .git_command_failed },
        .object => |object| switch (object.kind) {
            .commit => return .{ .oid = object.oid },
            .tag => {
                const peel = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{object.oid.slice()});
                defer allocator.free(peel);
                return switch (try batchCheck(allocator, io, context, format, peel)) {
                    .object => |peeled| if (peeled.kind == .commit)
                        .{ .oid = peeled.oid }
                    else
                        .{ .failure = .non_commit_object },
                    .missing => .{ .failure = .object_unavailable },
                    .failed => .{ .failure = .git_command_failed },
                };
            },
            .blob, .other => return .{ .failure = .non_commit_object },
        },
    }
}

const BatchKind = enum { commit, tag, blob, other };
const BatchObject = struct { oid: ObjectId, kind: BatchKind };
const BatchResult = union(enum) { object: BatchObject, missing, failed };

fn batchCheck(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    expression: []const u8,
) std.mem.Allocator.Error!BatchResult {
    return batchCheckWithGit(allocator, io, context, format, expression, strict_prefix[0]);
}

fn batchCheckWithGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    expression: []const u8,
    git_executable: []const u8,
) std.mem.Allocator.Error!BatchResult {
    const stdin = try std.fmt.allocPrint(allocator, "{s}\n", .{expression});
    defer allocator.free(stdin);
    const argv = [_][]const u8{
        git_executable, strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "cat-file",     "--batch-check",
    };
    var result = try git_command.runWithStdinBounded(allocator, io, context, .{
        .argv = &argv,
        .stdin = stdin,
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    if (!termExited(completed.term, 0)) return .failed;
    const line = singleLfLine(completed.stdout) orelse return .failed;
    if (std.mem.endsWith(u8, line, " missing")) return .missing;
    var fields = std.mem.splitScalar(u8, line, ' ');
    const oid_text = fields.next() orelse return .failed;
    const type_text = fields.next() orelse return .failed;
    const size_text = fields.next() orelse return .failed;
    if (fields.next() != null or size_text.len == 0) return .failed;
    for (size_text) |byte| if (!std.ascii.isDigit(byte)) return .failed;
    const oid = ObjectId.parse(format, oid_text) catch return .failed;
    const kind: BatchKind = if (std.mem.eql(u8, type_text, "commit"))
        .commit
    else if (std.mem.eql(u8, type_text, "tag"))
        .tag
    else if (std.mem.eql(u8, type_text, "blob"))
        .blob
    else
        .other;
    return .{ .object = .{ .oid = oid, .kind = kind } };
}

const MergeBaseResult = union(enum) { oid: ObjectId, no_merge_base, ambiguous, graph_unavailable, failed };

fn resolveMergeBase(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    base_oid: ObjectId,
    head_oid: ObjectId,
) std.mem.Allocator.Error!MergeBaseResult {
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "merge-base",     "--all",          base_oid.slice(), head_oid.slice(),
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited((format.oidHexLength() + 1) * 2),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .stdout_limit_exceeded => return .ambiguous,
        .stderr_limit_exceeded, .failed => return .failed,
        .completed => |value| value,
    };
    var records: [2]ObjectId = undefined;
    const count = parseOidRecords(format, completed.stdout, &records) orelse return .failed;
    return switch (completed.term) {
        .exited => |code| if (code == 0)
            if (count == 1) .{ .oid = records[0] } else if (count > 1) .ambiguous else .failed
        else if (code == 1 and count == 0)
            .no_merge_base
        else
            .graph_unavailable,
        else => .failed,
    };
}

fn endpointFailure(side: EndpointSide, failure: EndpointFailure) TargetResolutionFailure {
    return switch (side) {
        .base => switch (failure) {
            .unsupported_commitish => .base_unsupported_commitish,
            .unresolved => .base_unresolved,
            .ambiguous => .base_ambiguous,
            .non_commit_object => .base_non_commit_object,
            .object_unavailable => .base_object_unavailable,
            .git_command_failed => .git_command_failed,
        },
        .head => switch (failure) {
            .unsupported_commitish => .head_unsupported_commitish,
            .unresolved => .head_unresolved,
            .ambiguous => .head_ambiguous,
            .non_commit_object => .head_non_commit_object,
            .object_unavailable => .head_object_unavailable,
            .git_command_failed => .git_command_failed,
        },
    };
}

fn parseSingleOid(format: ObjectFormat, bytes: []const u8) ?ObjectId {
    const line = singleLfLine(bytes) orelse return null;
    return ObjectId.parse(format, line) catch null;
}

fn parseOidRecords(format: ObjectFormat, bytes: []const u8, output: *[2]ObjectId) ?usize {
    if (bytes.len == 0) return 0;
    if (bytes[bytes.len - 1] != '\n' or std.mem.indexOfScalar(u8, bytes, '\r') != null) return null;
    var records = std.mem.splitScalar(u8, bytes[0 .. bytes.len - 1], '\n');
    var count: usize = 0;
    while (records.next()) |record| {
        if (record.len == 0 or count == output.len) return null;
        output[count] = ObjectId.parse(format, record) catch return null;
        count += 1;
    }
    return count;
}

fn singleLfLine(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return null;
    const line = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfScalar(u8, line, '\n') != null or std.mem.indexOfScalar(u8, line, '\r') != null) return null;
    return line;
}

fn termExited(term: std.process.Child.Term, expected: u8) bool {
    return switch (term) {
        .exited => |code| code == expected,
        else => false,
    };
}

fn parseLsTreeRecord(format: ObjectFormat, bytes: []const u8, expected_path: []const u8) ?ObjectId {
    if (bytes.len < 2 or bytes[bytes.len - 1] != 0 or
        std.mem.indexOfScalar(u8, bytes[0 .. bytes.len - 1], 0) != null)
    {
        return null;
    }
    const record = bytes[0 .. bytes.len - 1];
    const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return null;
    if (!std.mem.eql(u8, record[tab + 1 ..], expected_path)) return null;
    var fields = std.mem.splitScalar(u8, record[0..tab], ' ');
    _ = fields.next() orelse return null;
    const kind = fields.next() orelse return null;
    const oid_text = fields.next() orelse return null;
    if (fields.next() != null or !std.mem.eql(u8, kind, "blob")) return null;
    return ObjectId.parse(format, oid_text) catch null;
}

fn selectLines(bytes: []const u8, start_line: u32, end_line: u32) ?[]const u8 {
    var line: u32 = 1;
    var cursor: usize = 0;
    var selected_start: ?usize = null;
    while (cursor < bytes.len) {
        const line_start = cursor;
        const lf = std.mem.indexOfScalarPos(u8, bytes, cursor, '\n');
        const line_end = if (lf) |index| index + 1 else bytes.len;
        if (line == start_line) selected_start = line_start;
        if (line == end_line) {
            const start = selected_start orelse return null;
            return bytes[start..line_end];
        }
        cursor = line_end;
        line += 1;
    }
    return null;
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

fn testRawProjection(io: std.Io, cwd: std.Io.Dir, target: CommittedReviewTarget) ![]u8 {
    const attr_source = try std.fmt.allocPrint(std.testing.allocator, "--attr-source={s}", .{target.head_oid.slice()});
    defer std.testing.allocator.free(attr_source);
    const argv = [_][]const u8{
        strict_prefix[0],        strict_prefix[1],  strict_prefix[2],  strict_prefix[3],
        attr_source,             "diff",            "--no-color",      "--no-ext-diff",
        "--no-textconv",         "--src-prefix=a/", "--dst-prefix=b/", target.diff_base_oid.slice(),
        target.head_oid.slice(),
    };
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(max_projection_bytes + 2 * 1024 * 1024),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    errdefer freeRunResult(std.testing.allocator, result);
    if (!termExited(result.term, 0)) {
        freeRunResult(std.testing.allocator, result);
        return error.GitCommandFailed;
    }
    std.testing.allocator.free(result.stderr);
    return result.stdout;
}

fn testOutputLine(bytes: []const u8) ![]const u8 {
    return singleLfLine(bytes) orelse error.ExpectedSingleLine;
}

fn expectTarget(result: TargetResolutionResult) !CommittedReviewTarget {
    return switch (result) {
        .target => |target| target,
        .failure => return error.ExpectedTarget,
    };
}

fn testObjectId(format: ObjectFormat, byte: u8) ObjectId {
    var oid: ObjectId = .{ .len = @intCast(format.oidHexLength()) };
    @memset(oid.bytes[0..format.oidHexLength()], byte);
    return oid;
}

test "review history backend availability parser requires exact three ordered commit records" {
    const target: CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = testObjectId(.sha1, '1'),
        .head_oid = testObjectId(.sha1, '2'),
        .diff_base_oid = testObjectId(.sha1, '3'),
    };
    const output = try std.fmt.allocPrint(std.testing.allocator, "{s} commit\n{s} missing\n{s} commit\n", .{ target.base_oid.slice(), target.head_oid.slice(), target.diff_base_oid.slice() });
    defer std.testing.allocator.free(output);
    const statuses = try parseAvailabilityRecords(std.testing.allocator, &.{target}, output);
    defer std.testing.allocator.free(statuses);
    try std.testing.expectEqual(TargetAvailability.missing, statuses[0]);

    const wrong_type = try std.fmt.allocPrint(std.testing.allocator, "{s} commit\n{s} tree\n{s} commit\n", .{ target.base_oid.slice(), target.head_oid.slice(), target.diff_base_oid.slice() });
    defer std.testing.allocator.free(wrong_type);
    try std.testing.expectError(
        error.InvalidAvailabilityOutput,
        parseAvailabilityRecords(std.testing.allocator, &.{target}, wrong_type),
    );
    try std.testing.expectError(
        error.InvalidAvailabilityOutput,
        parseAvailabilityRecords(std.testing.allocator, &.{target}, output[0 .. output.len - 1]),
    );
}

fn inventoryLineLessThan(_: void, left: []u8, right: []u8) bool {
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
    std.mem.sort([]u8, lines.items, {}, inventoryLineLessThan);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (lines.items) |line| try result.appendSlice(allocator, line);
    return result.toOwnedSlice(allocator);
}

const RefMovementTestContext = struct {
    base_ref: []const u8,
    new_base_oid: []const u8,
    head_ref: []const u8,
    new_head_oid: []const u8,

    fn move(context_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) anyerror!void {
        const context: *@This() = @ptrCast(@alignCast(context_ptr));
        try runTestGit(io, cwd, &.{ "git", "update-ref", context.base_ref, context.new_base_oid });
        try runTestGit(io, cwd, &.{ "git", "update-ref", context.head_ref, context.new_head_oid });
    }
};

test "target resolver ends at pinned target and projection and anchor are separate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try runTestGit(io, tmp.dir, &.{ "git", "switch", "-c", "feature" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\nfeature\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "feature" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const resolved = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "refs/heads/main",
        .head = "HEAD",
    });
    const target = switch (resolved) {
        .target => |value| value,
        .failure => return error.ExpectedTarget,
    };
    try std.testing.expect(target.base_oid.eql(&target.diff_base_oid));

    const ahead = try computeAheadDisplay(std.testing.allocator, io, context, target);
    try std.testing.expectEqual(@as(u64, 1), ahead.count);
    var projection = try materializeCommittedProjection(std.testing.allocator, io, context, target);
    defer projection.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, projection.projection.patch_bytes, "+feature") != null);

    const digest = wire.Sha256Digest.hash("feature\n");
    var anchor = try resolveCodeAnchor(std.testing.allocator, io, context, target, .{
        .path_bytes = "file.txt",
        .side = .after,
        .start_line = 2,
        .end_line = 2,
        .content_digest = digest,
    });
    defer anchor.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("feature\n", anchor.resolved.selected_bytes);
    var before = try resolveCodeAnchor(std.testing.allocator, io, context, target, .{
        .path_bytes = "file.txt",
        .side = .before,
        .start_line = 1,
        .end_line = 1,
        .content_digest = wire.Sha256Digest.hash("base\n"),
    });
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("base\n", before.resolved.selected_bytes);
}

test "finding projection source keeps byte-identical patch and lossless endpoint identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "modify.txt", .data = "old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "rename-old.txt", .data = "rename\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "delete.txt", .data = "delete\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "binary.dat", .data = "old\x00binary" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "." });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });

    try tmp.dir.writeFile(io, .{ .sub_path = "modify.txt", .data = "new\n" });
    try tmp.dir.rename("rename-old.txt", tmp.dir, "rename-new.txt", io);
    try tmp.dir.deleteFile(io, "delete.txt");
    try tmp.dir.writeFile(io, .{ .sub_path = "add.txt", .data = "add\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "binary.dat", .data = "new\x00binary" });
    const raw_path = "raw-\xff.txt";
    try tmp.dir.writeFile(io, .{ .sub_path = raw_path, .data = "raw\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "-A" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "HEAD^",
        .head = "HEAD",
    }));
    var ordinary = try materializeCommittedProjection(std.testing.allocator, io, context, target);
    defer ordinary.deinit(std.testing.allocator);
    var combined = try materializeCommittedFindingProjectionSource(std.testing.allocator, io, context, target);
    defer combined.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, ordinary.projection.patch_bytes, combined.source.projection.patch_bytes);
    try std.testing.expectEqual(@as(usize, 6), combined.source.endpoints.records.len);

    var modify_record: ?*const CommittedDiffEndpointRecord = null;
    var rename_record: ?*const CommittedDiffEndpointRecord = null;
    var add_record: ?*const CommittedDiffEndpointRecord = null;
    var delete_record: ?*const CommittedDiffEndpointRecord = null;
    var binary_record: ?*const CommittedDiffEndpointRecord = null;
    var raw_record: ?*const CommittedDiffEndpointRecord = null;
    for (combined.source.endpoints.records) |*record| {
        if (record.before) |before_endpoint| {
            if (std.mem.eql(u8, before_endpoint.path_bytes, "modify.txt")) modify_record = record;
            if (std.mem.eql(u8, before_endpoint.path_bytes, "rename-old.txt")) rename_record = record;
            if (std.mem.eql(u8, before_endpoint.path_bytes, "delete.txt")) delete_record = record;
            if (std.mem.eql(u8, before_endpoint.path_bytes, "binary.dat")) binary_record = record;
        } else if (record.after) |after_endpoint| {
            if (std.mem.eql(u8, after_endpoint.path_bytes, "add.txt")) add_record = record;
            if (std.mem.eql(u8, after_endpoint.path_bytes, raw_path)) raw_record = record;
        }
    }

    const modify_before_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD^:modify.txt" });
    defer std.testing.allocator.free(modify_before_output);
    const modify_after_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD:modify.txt" });
    defer std.testing.allocator.free(modify_after_output);
    const rename_before_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD^:rename-old.txt" });
    defer std.testing.allocator.free(rename_before_output);
    const rename_after_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD:rename-new.txt" });
    defer std.testing.allocator.free(rename_after_output);
    const delete_before_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD^:delete.txt" });
    defer std.testing.allocator.free(delete_before_output);
    const add_after_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD:add.txt" });
    defer std.testing.allocator.free(add_after_output);
    const binary_before_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD^:binary.dat" });
    defer std.testing.allocator.free(binary_before_output);
    const binary_after_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD:binary.dat" });
    defer std.testing.allocator.free(binary_after_output);
    const raw_after_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD:raw-\xff.txt" });
    defer std.testing.allocator.free(raw_after_output);
    const modify_before_oid = try testOutputLine(modify_before_output);
    const modify_after_oid = try testOutputLine(modify_after_output);
    const rename_before_oid = try testOutputLine(rename_before_output);
    const rename_after_oid = try testOutputLine(rename_after_output);
    const delete_before_oid = try testOutputLine(delete_before_output);
    const add_after_oid = try testOutputLine(add_after_output);
    const binary_before_oid = try testOutputLine(binary_before_output);
    const binary_after_oid = try testOutputLine(binary_after_output);
    const raw_after_oid = try testOutputLine(raw_after_output);
    const regular_mode = "100644";
    const absent_mode = "000000";

    const modify = modify_record orelse return error.ExpectedModifyEndpoint;
    try std.testing.expectEqualStrings("M", modify.status_bytes);
    try std.testing.expectEqualSlices(u8, regular_mode, &modify.old_mode);
    try std.testing.expectEqualSlices(u8, regular_mode, &modify.new_mode);
    try std.testing.expectEqualStrings("modify.txt", modify.before.?.path_bytes);
    try std.testing.expectEqualStrings("modify.txt", modify.after.?.path_bytes);
    try std.testing.expectEqualStrings(modify_before_oid, modify.before.?.object_oid.slice());
    try std.testing.expectEqualStrings(modify_after_oid, modify.after.?.object_oid.slice());
    try std.testing.expectEqualSlices(u8, regular_mode, &modify.before.?.mode);
    try std.testing.expectEqualSlices(u8, regular_mode, &modify.after.?.mode);
    try std.testing.expect(modify.before.?.is_blob and modify.after.?.is_blob);

    const rename = rename_record orelse return error.ExpectedRenameEndpoint;
    try std.testing.expectEqualStrings("R100", rename.status_bytes);
    try std.testing.expectEqualSlices(u8, regular_mode, &rename.old_mode);
    try std.testing.expectEqualSlices(u8, regular_mode, &rename.new_mode);
    try std.testing.expectEqualStrings("rename-old.txt", rename.before.?.path_bytes);
    try std.testing.expectEqualStrings("rename-new.txt", rename.after.?.path_bytes);
    try std.testing.expectEqualStrings(rename_before_oid, rename.before.?.object_oid.slice());
    try std.testing.expectEqualStrings(rename_after_oid, rename.after.?.object_oid.slice());
    try std.testing.expectEqualSlices(u8, regular_mode, &rename.before.?.mode);
    try std.testing.expectEqualSlices(u8, regular_mode, &rename.after.?.mode);
    try std.testing.expect(rename.before.?.is_blob and rename.after.?.is_blob);

    const add = add_record orelse return error.ExpectedAddEndpoint;
    try std.testing.expectEqualStrings("A", add.status_bytes);
    try std.testing.expectEqualSlices(u8, absent_mode, &add.old_mode);
    try std.testing.expectEqualSlices(u8, regular_mode, &add.new_mode);
    try std.testing.expect(add.before == null);
    try std.testing.expectEqualStrings("add.txt", add.after.?.path_bytes);
    try std.testing.expectEqualStrings(add_after_oid, add.after.?.object_oid.slice());
    try std.testing.expectEqualSlices(u8, regular_mode, &add.after.?.mode);
    try std.testing.expect(add.after.?.is_blob);

    const deleted = delete_record orelse return error.ExpectedDeleteEndpoint;
    try std.testing.expectEqualStrings("D", deleted.status_bytes);
    try std.testing.expectEqualSlices(u8, regular_mode, &deleted.old_mode);
    try std.testing.expectEqualSlices(u8, absent_mode, &deleted.new_mode);
    try std.testing.expectEqualStrings("delete.txt", deleted.before.?.path_bytes);
    try std.testing.expectEqualStrings(delete_before_oid, deleted.before.?.object_oid.slice());
    try std.testing.expectEqualSlices(u8, regular_mode, &deleted.before.?.mode);
    try std.testing.expect(deleted.before.?.is_blob);
    try std.testing.expect(deleted.after == null);

    const binary = binary_record orelse return error.ExpectedBinaryEndpoint;
    try std.testing.expectEqualStrings("M", binary.status_bytes);
    try std.testing.expectEqualSlices(u8, regular_mode, &binary.old_mode);
    try std.testing.expectEqualSlices(u8, regular_mode, &binary.new_mode);
    try std.testing.expectEqualStrings("binary.dat", binary.before.?.path_bytes);
    try std.testing.expectEqualStrings("binary.dat", binary.after.?.path_bytes);
    try std.testing.expectEqualStrings(binary_before_oid, binary.before.?.object_oid.slice());
    try std.testing.expectEqualStrings(binary_after_oid, binary.after.?.object_oid.slice());
    try std.testing.expectEqualSlices(u8, regular_mode, &binary.before.?.mode);
    try std.testing.expectEqualSlices(u8, regular_mode, &binary.after.?.mode);
    try std.testing.expect(binary.before.?.is_blob and binary.after.?.is_blob);

    const raw = raw_record orelse return error.ExpectedRawEndpoint;
    try std.testing.expectEqualStrings("A", raw.status_bytes);
    try std.testing.expectEqualSlices(u8, absent_mode, &raw.old_mode);
    try std.testing.expectEqualSlices(u8, regular_mode, &raw.new_mode);
    try std.testing.expect(raw.before == null);
    try std.testing.expectEqualSlices(u8, raw_path, raw.after.?.path_bytes);
    try std.testing.expectEqualStrings(raw_after_oid, raw.after.?.object_oid.slice());
    try std.testing.expectEqualSlices(u8, regular_mode, &raw.after.?.mode);
    try std.testing.expect(raw.after.?.is_blob);

    const same_target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "HEAD",
        .head = "HEAD",
    }));
    var empty = try materializeCommittedFindingProjectionSource(std.testing.allocator, io, context, same_target);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.source.projection.patch_bytes.len);
    try std.testing.expectEqual(@as(usize, 0), empty.source.endpoints.records.len);

    const oid = "1111111111111111111111111111111111111111";
    const malformed = try std.fmt.allocPrint(std.testing.allocator, ":100644 100644 {s} {s} M\x00unterminated", .{ oid, oid });
    defer std.testing.allocator.free(malformed);
    try std.testing.expectError(error.InvalidRawDiff, parseCombinedDiffSource(std.testing.allocator, target, malformed));

    const raw_exact = try std.testing.allocator.alloc(u8, max_projection_bytes);
    defer std.testing.allocator.free(raw_exact);
    @memset(raw_exact, 'x');
    raw_exact[raw_exact.len - 2] = 0;
    raw_exact[raw_exact.len - 1] = 0;
    const raw_exact_bounds = combinedComponentBounds(raw_exact);
    try std.testing.expect(raw_exact_bounds == .patch_start);
    try std.testing.expectEqual(max_projection_bytes, raw_exact_bounds.patch_start);
    const raw_over = try std.testing.allocator.alloc(u8, max_projection_bytes + 1);
    defer std.testing.allocator.free(raw_over);
    @memset(raw_over, 'x');
    raw_over[raw_over.len - 2] = 0;
    raw_over[raw_over.len - 1] = 0;
    try std.testing.expect(combinedComponentBounds(raw_over) == .too_large);
    const patch_over = try std.testing.allocator.alloc(u8, max_projection_bytes + 3);
    defer std.testing.allocator.free(patch_over);
    @memset(patch_over, 'x');
    patch_over[0] = 0;
    patch_over[1] = 0;
    try std.testing.expect(combinedComponentBounds(patch_over) == .too_large);

    const contradictory_patch =
        "diff --git a/one.txt b/one.txt\n" ++
        "--- a/one.txt\n" ++
        "+++ b/one.txt\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n" ++
        "diff --git a/two.txt b/two.txt\n" ++
        "--- a/two.txt\n" ++
        "+++ b/two.txt\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n";
    const contradictory = try std.fmt.allocPrint(
        std.testing.allocator,
        ":100644 100644 {s} {s} M\x00one.txt\x00\x00{s}",
        .{ oid, oid, contradictory_patch },
    );
    defer std.testing.allocator.free(contradictory);
    var contradictory_result = try buildFindingProjectionSourceFromCombined(
        std.testing.allocator,
        target,
        contradictory,
    );
    defer contradictory_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(ProjectionFailure.projection_git_command_failed, contradictory_result.failure);
}

test "CodeAnchor batch reads each exact path and distinct blob once per operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "one\ntwo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two.txt", .data = "one\ntwo\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "." });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "anchor" });

    const root_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const log_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "commands.log" });
    defer std.testing.allocator.free(log_path);
    const script = "#!/bin/sh\nprintf '%s\n' \"$*\" >> \"$OBSERVER_LOG\"\nexec git \"$@\"\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "git-observer", .data = script });
    try runTestGit(io, tmp.dir, &.{ "chmod", "+x", "git-observer" });
    const observer_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "git-observer" });
    defer std.testing.allocator.free(observer_path);
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("OBSERVER_LOG", log_path);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, &parent);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "HEAD",
        .head = "HEAD",
    }));
    const anchors = [_]CodeAnchor{
        .{ .path_bytes = "one.txt", .side = .after, .start_line = 1, .end_line = 1, .content_digest = wire.Sha256Digest.hash("one\n") },
        .{ .path_bytes = "one.txt", .side = .after, .start_line = 2, .end_line = 2, .content_digest = wire.Sha256Digest.hash("two\n") },
        .{ .path_bytes = "two.txt", .side = .after, .start_line = 1, .end_line = 2, .content_digest = wire.Sha256Digest.hash("one\ntwo\n") },
    };
    inline for (0..2) |_| {
        const batch = try resolveCodeAnchorsInternal(
            std.testing.allocator,
            io,
            context,
            target,
            &anchors,
            null,
            observer_path,
        );
        defer std.testing.allocator.free(batch.validations);
        for (batch.validations) |validation| try std.testing.expect(validation == .validated);
        try std.testing.expect(batch.selected_bytes == null);
    }
    const log = try tmp.dir.readFileAlloc(io, "commands.log", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(log);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, log, "ls-tree -rz"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, log, "cat-file blob"));
}

test "CodeAnchor reads exact committed bytes and keeps path blob range digest and size terminals separate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.createDir(io, "dir", .default_dir);
    const raw_path = "raw-\xff";
    try tmp.dir.writeFile(io, .{ .sub_path = "dir/nested", .data = "nested\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "text.txt", .data = "one\r\ntwo\nlast" });
    try tmp.dir.writeFile(io, .{ .sub_path = "binary.dat", .data = "binary\x00bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = raw_path, .data = "raw path\n" });
    const exact_bytes = try std.testing.allocator.alloc(u8, max_anchor_blob_bytes);
    @memset(exact_bytes, 'x');
    const exact_digest = wire.Sha256Digest.hash(exact_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "exact.txt", .data = exact_bytes });
    std.testing.allocator.free(exact_bytes);
    const over_bytes = try std.testing.allocator.alloc(u8, max_anchor_blob_bytes + 1);
    @memset(over_bytes, 'y');
    try tmp.dir.writeFile(io, .{ .sub_path = "over.txt", .data = over_bytes });
    std.testing.allocator.free(over_bytes);
    try runTestGit(io, tmp.dir, &.{ "git", "add", "." });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "anchor" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "HEAD",
        .head = "HEAD",
    }));

    const foreign_draft_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "testdata/committed-review-v1/negative/draft-note-foreign-anchor.json",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(foreign_draft_bytes);
    var foreign_draft = try wire.ReviewDraftState.parseStrict(std.testing.allocator, foreign_draft_bytes);
    defer foreign_draft.deinit();
    var foreign_note = try resolveCodeAnchor(
        std.testing.allocator,
        io,
        context,
        target,
        foreign_draft.value.anchored_notes[0].anchor,
    );
    defer foreign_note.deinit(std.testing.allocator);
    try std.testing.expectEqual(CodeAnchorFailure.path_not_found, foreign_note.failure);

    var crlf = try resolveCodeAnchor(std.testing.allocator, io, context, target, .{
        .path_bytes = "text.txt",
        .side = .after,
        .start_line = 1,
        .end_line = 1,
        .content_digest = wire.Sha256Digest.hash("one\r\n"),
    });
    defer crlf.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("one\r\n", crlf.resolved.selected_bytes);
    var final_no_lf = try resolveCodeAnchor(std.testing.allocator, io, context, target, .{
        .path_bytes = "text.txt",
        .side = .after,
        .start_line = 3,
        .end_line = 3,
        .content_digest = wire.Sha256Digest.hash("last"),
    });
    defer final_no_lf.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("last", final_no_lf.resolved.selected_bytes);
    var raw_name = try resolveCodeAnchor(std.testing.allocator, io, context, target, .{
        .path_bytes = raw_path,
        .side = .after,
        .start_line = 1,
        .end_line = 1,
        .content_digest = wire.Sha256Digest.hash("raw path\n"),
    });
    defer raw_name.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("raw path\n", raw_name.resolved.selected_bytes);

    const cases = [_]struct { path: []const u8, start: u32, digest: wire.Sha256Digest, failure: CodeAnchorFailure }{
        .{ .path = "missing", .start = 1, .digest = wire.Sha256Digest.hash("x"), .failure = .path_not_found },
        .{ .path = "dir", .start = 1, .digest = wire.Sha256Digest.hash("x"), .failure = .path_not_blob },
        .{ .path = "binary.dat", .start = 1, .digest = wire.Sha256Digest.hash("binary\x00bytes"), .failure = .binary_blob },
        .{ .path = "empty.txt", .start = 1, .digest = wire.Sha256Digest.hash(""), .failure = .range_out_of_bounds },
        .{ .path = "text.txt", .start = 4, .digest = wire.Sha256Digest.hash("x"), .failure = .range_out_of_bounds },
        .{ .path = "text.txt", .start = 1, .digest = wire.Sha256Digest.hash("wrong"), .failure = .content_digest_mismatch },
    };
    for (cases) |case| {
        var result = try resolveCodeAnchor(std.testing.allocator, io, context, target, .{
            .path_bytes = case.path,
            .side = .after,
            .start_line = case.start,
            .end_line = case.start,
            .content_digest = case.digest,
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.failure, result.failure);
    }
    const oversized_path = try std.testing.allocator.alloc(u8, wire.limits.max_raw_path_bytes + 1);
    defer std.testing.allocator.free(oversized_path);
    @memset(oversized_path, 'p');
    var invalid_path = try resolveCodeAnchor(std.testing.allocator, io, context, target, .{
        .path_bytes = oversized_path,
        .side = .after,
        .start_line = 1,
        .end_line = 1,
        .content_digest = wire.Sha256Digest.hash("unused"),
    });
    defer invalid_path.deinit(std.testing.allocator);
    try std.testing.expectEqual(CodeAnchorFailure.invalid_anchor, invalid_path.failure);

    var exact = try resolveCodeAnchor(std.testing.allocator, io, context, target, .{
        .path_bytes = "exact.txt",
        .side = .after,
        .start_line = 1,
        .end_line = 1,
        .content_digest = exact_digest,
    });
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_anchor_blob_bytes, exact.resolved.selected_bytes.len);
    var over = try resolveCodeAnchor(std.testing.allocator, io, context, target, .{
        .path_bytes = "over.txt",
        .side = .after,
        .start_line = 1,
        .end_line = 1,
        .content_digest = wire.Sha256Digest.hash("unused"),
    });
    defer over.deinit(std.testing.allocator);
    try std.testing.expectEqual(CodeAnchorFailure.blob_too_large, over.failure);
}

test "projection ignores dirty staged and untracked versioned attributes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.createDir(io, "nested", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.dat -diff\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data.dat", .data = "old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/data.dat", .data = "nested old\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", ".gitattributes", "data.dat", "nested/data.dat" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try runTestGit(io, tmp.dir, &.{ "git", "switch", "-c", "feature" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.dat diff\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data.dat", .data = "new\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/data.dat", .data = "nested new\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", ".gitattributes", "data.dat", "nested/data.dat" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "feature" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const resolved = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "main",
        .head = "HEAD",
    });
    const target = resolved.target;
    var clean = try materializeCommittedProjection(std.testing.allocator, io, context, target);
    defer clean.deinit(std.testing.allocator);
    const clean_digest = wire.Sha256Digest.hash(clean.projection.patch_bytes);

    try runTestGit(io, tmp.dir, &.{ "git", "replace", target.head_oid.slice(), target.base_oid.slice() });
    const replacement_resolved = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "main",
        .head = "HEAD",
    }));
    try std.testing.expect(target.eql(&replacement_resolved));
    var replacement_ignored = try materializeCommittedProjection(std.testing.allocator, io, context, target);
    defer replacement_ignored.deinit(std.testing.allocator);
    try std.testing.expect(clean_digest.eql(wire.Sha256Digest.hash(replacement_ignored.projection.patch_bytes)));

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.dat -diff\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data.dat", .data = "dirty worktree\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/data.dat", .data = "nested dirty worktree\n" });
    var dirty = try materializeCommittedProjection(std.testing.allocator, io, context, target);
    defer dirty.deinit(std.testing.allocator);
    try std.testing.expect(clean_digest.eql(wire.Sha256Digest.hash(dirty.projection.patch_bytes)));
    try runTestGit(io, tmp.dir, &.{ "git", "add", ".gitattributes", "data.dat", "nested/data.dat" });
    var staged = try materializeCommittedProjection(std.testing.allocator, io, context, target);
    defer staged.deinit(std.testing.allocator);
    try std.testing.expect(clean_digest.eql(wire.Sha256Digest.hash(staged.projection.patch_bytes)));
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/.gitattributes", .data = "*.dat -diff\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "untracked.dat", .data = "untracked content\n" });
    var untracked = try materializeCommittedProjection(std.testing.allocator, io, context, target);
    defer untracked.deinit(std.testing.allocator);
    try std.testing.expect(clean_digest.eql(wire.Sha256Digest.hash(untracked.projection.patch_bytes)));

    const selected_digest = wire.Sha256Digest.hash("nested new\n");
    var anchor_before_policy = try resolveCodeAnchor(std.testing.allocator, io, context, target, .{
        .path_bytes = "nested/data.dat",
        .side = .after,
        .start_line = 1,
        .end_line = 1,
        .content_digest = selected_digest,
    });
    defer anchor_before_policy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("nested new\n", anchor_before_policy.resolved.selected_bytes);

    try tmp.dir.writeFile(io, .{ .sub_path = ".git/info/attributes", .data = "*.dat -diff\n" });
    var local_policy = try materializeCommittedProjection(std.testing.allocator, io, context, target);
    defer local_policy.deinit(std.testing.allocator);
    try std.testing.expect(!clean_digest.eql(wire.Sha256Digest.hash(local_policy.projection.patch_bytes)));
    var anchor_after_policy = try resolveCodeAnchor(std.testing.allocator, io, context, target, .{
        .path_bytes = "nested/data.dat",
        .side = .after,
        .start_line = 1,
        .end_line = 1,
        .content_digest = selected_digest,
    });
    defer anchor_after_policy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("nested new\n", anchor_after_policy.resolved.selected_bytes);

    const root_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const marker_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "effect-marker" });
    defer std.testing.allocator.free(marker_path);
    const script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\nprintf invoked > '{s}'\ncat\n", .{marker_path});
    defer std.testing.allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "effect-helper.sh", .data = script });
    try runTestGit(io, tmp.dir, &.{ "chmod", "+x", "effect-helper.sh" });
    const helper_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "effect-helper.sh" });
    defer std.testing.allocator.free(helper_path);
    try runTestGit(io, tmp.dir, &.{ "git", "config", "diff.evil.textconv", helper_path });
    try runTestGit(io, tmp.dir, &.{ "git", "config", "diff.external", helper_path });
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/info/attributes", .data = "*.dat diff=evil\n" });
    var effects_disabled = try materializeCommittedProjection(std.testing.allocator, io, context, target);
    defer effects_disabled.deinit(std.testing.allocator);
    try std.testing.expect(effects_disabled == .projection);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "effect-marker", .{}));

    try runTestGit(io, tmp.dir, &.{ "git", "config", "diff.algorithm", "definitely-invalid" });
    var invalid_config = try materializeCommittedProjection(std.testing.allocator, io, context, target);
    defer invalid_config.deinit(std.testing.allocator);
    try std.testing.expectEqual(ProjectionFailure.projection_git_command_failed, invalid_config.failure);
}

test "projection closes completed nonzero signal and stderr overflow to one generic terminal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const log_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "invocations" });
    defer std.testing.allocator.free(log_path);
    const args_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "argv" });
    defer std.testing.allocator.free(args_path);
    const script =
        "#!/bin/sh\n" ++
        "printf x >> \"$FAKE_LOG\"\n" ++
        "printf '%s\\n' \"$@\" > \"$FAKE_ARGS\"\n" ++
        "case \"$FAKE_MODE\" in\n" ++
        "  ok) printf 'binary\\000patch' ;;\n" ++
        "  nonzero) exit 7 ;;\n" ++
        "  unsupported_attr_source) printf unsupported >&2; exit 129 ;;\n" ++
        "  signal) kill -TERM $$ ;;\n" ++
        "  stderr) i=0; while [ \"$i\" -le 8192 ]; do printf e >&2; i=$((i + 1)); done ;;\n" ++
        "  *) exit 9 ;;\n" ++
        "esac\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "git", .data = script });
    try runTestGit(io, tmp.dir, &.{ "chmod", "+x", "git" });
    const git_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "git" });
    defer std.testing.allocator.free(git_path);

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", root_path);
    try parent.put("FAKE_LOG", log_path);
    try parent.put("FAKE_ARGS", args_path);
    try parent.put("FAKE_MODE", "ok");
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, &parent);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const target: CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = testObjectId(.sha1, 'a'),
        .head_oid = testObjectId(.sha1, 'b'),
        .diff_base_oid = testObjectId(.sha1, 'a'),
    };

    var ok = try materializeCommittedProjectionWithGit(std.testing.allocator, io, context, target, git_path);
    defer ok.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "binary\x00patch", ok.projection.patch_bytes);

    const modes = [_][]const u8{ "nonzero", "unsupported_attr_source", "signal", "stderr" };
    for (modes) |mode| {
        try environment.map.put("FAKE_MODE", mode);
        var result = try materializeCommittedProjectionWithGit(std.testing.allocator, io, context, target, git_path);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(ProjectionFailure.projection_git_command_failed, result.failure);
    }
    const invocations = try tmp.dir.readFileAlloc(io, "invocations", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(invocations);
    try std.testing.expectEqualStrings("xxxxx", invocations);
    const args = try tmp.dir.readFileAlloc(io, "argv", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(args);
    try std.testing.expectEqualStrings(
        "--no-replace-objects\n" ++
            "--no-lazy-fetch\n" ++
            "--no-optional-locks\n" ++
            "--attr-source=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
            "diff\n" ++
            "--no-color\n" ++
            "--no-ext-diff\n" ++
            "--no-textconv\n" ++
            "--src-prefix=a/\n" ++
            "--dst-prefix=b/\n" ++
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
        args,
    );
}

test "projection accepts exact sixteen MiB and rejects only the next stdout byte" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "large.txt diff\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", ".gitattributes" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try runTestGit(io, tmp.dir, &.{ "git", "switch", "-c", "boundary" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };

    const sample_size: usize = 4096;
    const sample = try std.testing.allocator.alloc(u8, sample_size);
    @memset(sample, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = sample });
    std.testing.allocator.free(sample);
    try runTestGit(io, tmp.dir, &.{ "git", "add", "large.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "sample" });
    const sample_target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "refs/heads/main",
        .head = "HEAD",
    }));
    const sample_patch = try testRawProjection(io, tmp.dir, sample_target);
    defer std.testing.allocator.free(sample_patch);
    try std.testing.expect(sample_patch.len > sample_size);
    const fixed_overhead = sample_patch.len - sample_size;
    try std.testing.expect(fixed_overhead < max_projection_bytes);
    const exact_file_size = max_projection_bytes - fixed_overhead;

    try runTestGit(io, tmp.dir, &.{ "git", "reset", "--hard", "refs/heads/main" });
    const exact_bytes = try std.testing.allocator.alloc(u8, exact_file_size);
    @memset(exact_bytes, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = exact_bytes });
    std.testing.allocator.free(exact_bytes);
    try runTestGit(io, tmp.dir, &.{ "git", "add", "large.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "exact" });
    const exact_target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "refs/heads/main",
        .head = "HEAD",
    }));
    const exact_ahead = try computeAheadDisplay(std.testing.allocator, io, context, exact_target);
    try std.testing.expectEqual(@as(u64, 1), exact_ahead.count);
    var exact = try materializeCommittedProjection(std.testing.allocator, io, context, exact_target);
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_projection_bytes, exact.projection.patch_bytes.len);
    var exact_source = try materializeCommittedFindingProjectionSource(std.testing.allocator, io, context, exact_target);
    defer exact_source.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_projection_bytes, exact_source.source.projection.patch_bytes.len);
    try std.testing.expectEqualSlices(u8, exact.projection.patch_bytes, exact_source.source.projection.patch_bytes);
    try std.testing.expectEqual(@as(usize, 1), exact_source.source.endpoints.records.len);

    try runTestGit(io, tmp.dir, &.{ "git", "reset", "--hard", "refs/heads/main" });
    const over_bytes = try std.testing.allocator.alloc(u8, exact_file_size + 1);
    @memset(over_bytes, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = over_bytes });
    std.testing.allocator.free(over_bytes);
    try runTestGit(io, tmp.dir, &.{ "git", "add", "large.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "over" });
    const over_target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "refs/heads/main",
        .head = "HEAD",
    }));
    const over_ahead = try computeAheadDisplay(std.testing.allocator, io, context, over_target);
    try std.testing.expectEqual(@as(u64, 1), over_ahead.count);
    var over = try materializeCommittedProjection(std.testing.allocator, io, context, over_target);
    defer over.deinit(std.testing.allocator);
    try std.testing.expectEqual(ProjectionFailure.projection_too_large, over.failure);
    var over_source = try materializeCommittedFindingProjectionSource(std.testing.allocator, io, context, over_target);
    defer over_source.deinit(std.testing.allocator);
    try std.testing.expectEqual(ProjectionFailure.projection_too_large, over_source.failure);
}

test "partial clone missing blob keeps target success and fails projection without helpers or ODB writes" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "source", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{});
    defer source.close(io);
    try runTestGit(io, source, &.{ "git", "init", "--initial-branch=main" });
    try source.writeFile(io, .{ .sub_path = "blob.txt", .data = "base blob\n" });
    try runTestGit(io, source, &.{ "git", "add", "blob.txt" });
    try runTestGit(io, source, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    const base_output = try testGitOutput(io, source, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(base_output);
    const base_oid = try testOutputLine(base_output);
    try source.writeFile(io, .{ .sub_path = "blob.txt", .data = "head blob\n" });
    try runTestGit(io, source, &.{ "git", "add", "blob.txt" });
    try runTestGit(io, source, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });
    const head_output = try testGitOutput(io, source, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_output);
    const head_oid = try testOutputLine(head_output);
    const blob_output = try testGitOutput(io, source, &.{ "git", "rev-parse", "HEAD:blob.txt" });
    defer std.testing.allocator.free(blob_output);
    const blob_oid = try testOutputLine(blob_output);

    try runTestGit(io, tmp.dir, &.{ "git", "clone", "--bare", "source", "origin.git" });
    var origin = try tmp.dir.openDir(io, "origin.git", .{});
    defer origin.close(io);
    try runTestGit(io, origin, &.{ "git", "config", "uploadpack.allowFilter", "true" });
    const origin_path = try tmp.dir.realPathFileAlloc(io, "origin.git", std.testing.allocator);
    defer std.testing.allocator.free(origin_path);
    const origin_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{origin_path});
    defer std.testing.allocator.free(origin_url);
    try runTestGit(io, tmp.dir, &.{ "git", "clone", "--filter=blob:none", "--no-checkout", origin_url, "partial" });
    var partial = try tmp.dir.openDir(io, "partial", .{});
    defer partial.close(io);

    const missing_check = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "git", "--no-lazy-fetch", "cat-file", "-e", blob_oid },
        .cwd = .{ .dir = partial },
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer freeRunResult(std.testing.allocator, missing_check);
    try std.testing.expect(!termExited(missing_check.term, 0));

    try tmp.dir.createDir(io, "helpers", .default_dir);
    const temp_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(temp_root);
    const helpers_path = try std.fs.path.join(std.testing.allocator, &.{ temp_root, "helpers" });
    defer std.testing.allocator.free(helpers_path);
    const remote_marker = try std.fs.path.join(std.testing.allocator, &.{ temp_root, "remote-helper-invoked" });
    defer std.testing.allocator.free(remote_marker);
    const credential_marker = try std.fs.path.join(std.testing.allocator, &.{ temp_root, "credential-helper-invoked" });
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
    try runTestGit(io, partial, &.{ "git", "remote", "set-url", "origin", "fake::missing" });
    try runTestGit(io, partial, &.{ "git", "config", "credential.helper", credential_config });

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    const helper_path_env = try std.fmt.allocPrint(std.testing.allocator, "{s}:/usr/bin:/bin", .{helpers_path});
    defer std.testing.allocator.free(helper_path_env);
    try parent.put("PATH", helper_path_env);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, &parent);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = partial, .environment = &environment };

    const status_before = try testGitOutput(io, partial, &.{ "git", "status", "--porcelain=v2", "--untracked-files=no" });
    defer std.testing.allocator.free(status_before);
    const inventory_before = try objectInventory(std.testing.allocator, io, partial);
    defer std.testing.allocator.free(inventory_before);

    const target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = base_oid,
        .head = head_oid,
    }));
    try std.testing.expectEqualStrings(base_oid, target.base_oid.slice());
    try std.testing.expectEqualStrings(head_oid, target.head_oid.slice());
    const ahead = try computeAheadDisplay(std.testing.allocator, io, context, target);
    try std.testing.expectEqual(@as(u64, 1), ahead.count);
    var projection = try materializeCommittedProjection(std.testing.allocator, io, context, target);
    defer projection.deinit(std.testing.allocator);
    try std.testing.expectEqual(ProjectionFailure.projection_git_command_failed, projection.failure);
    var anchor = try resolveCodeAnchor(std.testing.allocator, io, context, target, .{
        .path_bytes = "blob.txt",
        .side = .after,
        .start_line = 1,
        .end_line = 1,
        .content_digest = wire.Sha256Digest.hash("head blob\n"),
    });
    defer anchor.deinit(std.testing.allocator);
    try std.testing.expectEqual(CodeAnchorFailure.blob_object_unavailable, anchor.failure);

    const status_after = try testGitOutput(io, partial, &.{ "git", "status", "--porcelain=v2", "--untracked-files=no" });
    defer std.testing.allocator.free(status_after);
    try std.testing.expectEqualSlices(u8, status_before, status_after);
    const inventory_after = try objectInventory(std.testing.allocator, io, partial);
    defer std.testing.allocator.free(inventory_after);
    try std.testing.expectEqualSlices(u8, inventory_before, inventory_after);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "remote-helper-invoked", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "credential-helper-invoked", .{}));
}

test "promisor missing endpoint and graph stay typed without remote helper or ODB effects" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "graph\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "root" });
    const root_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(root_output);
    const root_oid = try testOutputLine(root_output);
    const tree_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD^{tree}" });
    defer std.testing.allocator.free(tree_output);
    const tree_oid = try testOutputLine(tree_output);
    const base_output = try testGitOutput(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-p", root_oid, "-m", "base" });
    defer std.testing.allocator.free(base_output);
    const base_oid = try testOutputLine(base_output);
    const head_output = try testGitOutput(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-p", root_oid, "-m", "head" });
    defer std.testing.allocator.free(head_output);
    const head_oid = try testOutputLine(head_output);

    try runTestGit(io, tmp.dir, &.{ "git", "config", "core.repositoryformatversion", "1" });
    try runTestGit(io, tmp.dir, &.{ "git", "config", "extensions.partialClone", "origin" });
    try runTestGit(io, tmp.dir, &.{ "git", "config", "remote.origin.promisor", "true" });
    try runTestGit(io, tmp.dir, &.{ "git", "config", "remote.origin.partialclonefilter", "blob:none" });
    try runTestGit(io, tmp.dir, &.{ "git", "config", "remote.origin.url", "fake::missing" });
    try tmp.dir.createDir(io, "helpers", .default_dir);
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const marker_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "remote-helper-invoked" });
    defer std.testing.allocator.free(marker_path);
    const helper_script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\nprintf invoked > '{s}'\nexit 1\n", .{marker_path});
    defer std.testing.allocator.free(helper_script);
    try tmp.dir.writeFile(io, .{ .sub_path = "helpers/git-remote-fake", .data = helper_script });
    try runTestGit(io, tmp.dir, &.{ "chmod", "+x", "helpers/git-remote-fake" });
    const helpers_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "helpers" });
    defer std.testing.allocator.free(helpers_path);

    const missing_path = try std.fmt.allocPrint(std.testing.allocator, ".git/objects/{s}/{s}", .{ root_oid[0..2], root_oid[2..] });
    defer std.testing.allocator.free(missing_path);
    try tmp.dir.deleteFile(io, missing_path);
    const missing_ref = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{root_oid});
    defer std.testing.allocator.free(missing_ref);
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/MISSING", .data = missing_ref });

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    const path_env = try std.fmt.allocPrint(std.testing.allocator, "{s}:/usr/bin:/bin", .{helpers_path});
    defer std.testing.allocator.free(path_env);
    try parent.put("PATH", path_env);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, &parent);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const inventory_before = try objectInventory(std.testing.allocator, io, tmp.dir);
    defer std.testing.allocator.free(inventory_before);

    const graph = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = base_oid,
        .head = head_oid,
    });
    try std.testing.expectEqual(TargetResolutionFailure.target_graph_unavailable, graph.failure);
    const endpoint_missing = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "MISSING",
        .head = head_oid,
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_object_unavailable, endpoint_missing.failure);
    const endpoint_missing_with_suffix = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "MISSING^{commit}",
        .head = head_oid,
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_object_unavailable, endpoint_missing_with_suffix.failure);

    const inventory_after = try objectInventory(std.testing.allocator, io, tmp.dir);
    defer std.testing.allocator.free(inventory_after);
    try std.testing.expectEqualSlices(u8, inventory_before, inventory_after);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "remote-helper-invoked", .{}));
}

test "unsupported commit-ish families fail before Git endpoint resolution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked", .data = "tracked\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "staged", .data = "staged\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "tracked" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "root" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "staged" });
    const head_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_output);
    const head_oid = try testOutputLine(head_output);
    const blob_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", ":staged" });
    defer std.testing.allocator.free(blob_output);
    const blob_oid = try testOutputLine(blob_output);
    const gitlink_record = try std.fmt.allocPrint(std.testing.allocator, "160000,{s},gitlink", .{head_oid});
    defer std.testing.allocator.free(gitlink_record);
    try runTestGit(io, tmp.dir, &.{ "git", "update-index", "--add", "--cacheinfo", gitlink_record });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const conflict_records = try std.fmt.allocPrint(
        std.testing.allocator,
        "100644 {s} 1\tconflict\n100644 {s} 2\tconflict\n100644 {s} 3\tconflict\n",
        .{ blob_oid, blob_oid, blob_oid },
    );
    defer std.testing.allocator.free(conflict_records);
    const update_argv = [_][]const u8{ "git", "update-index", "--index-info" };
    const update_result = try git_command.runWithStdin(std.testing.allocator, io, context, .{
        .argv = &update_argv,
        .stdin = conflict_records,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer update_result.deinit(std.testing.allocator);
    try std.testing.expect(termExited(update_result.term, 0));

    const rejected = [_][]const u8{
        ":path",         ":0:path",     ":1:path",     ":2:path",    ":3:path",
        "HEAD:path",     "HEAD..main",  "HEAD...main", "^HEAD",      "HEAD^@",
        "HEAD^!",        "HEAD^-2",     "HEAD@{1}",    "@",          ":/message",
        "HEAD^{/match}", "HEAD^{tree}", "HEAD^{blob}", "HEAD^{tag}", "HEAD^{object}",
        "--all",         "white space", "line\nfeed",
    };
    for (rejected) |value| {
        const base_result = try resolveTarget(std.testing.allocator, std.testing.io, context, .{
            .source_kind = .branch_range,
            .base = value,
            .head = "HEAD",
        });
        try std.testing.expectEqual(TargetResolutionFailure.base_unsupported_commitish, base_result.failure);
        const head_result = try resolveTarget(std.testing.allocator, std.testing.io, context, .{
            .source_kind = .branch_range,
            .base = "HEAD",
            .head = value,
        });
        try std.testing.expectEqual(TargetResolutionFailure.head_unsupported_commitish, head_result.failure);
    }
    const existing_index_objects = [_][]const u8{
        ":0:staged", ":0:gitlink", ":1:conflict", ":2:conflict", ":3:conflict",
    };
    for (existing_index_objects) |value| {
        const result = try resolveTarget(std.testing.allocator, io, context, .{
            .source_kind = .branch_range,
            .base = value,
            .head = "HEAD",
        });
        try std.testing.expectEqual(TargetResolutionFailure.base_unsupported_commitish, result.failure);
    }
}

test "resolver pins full abbreviated ref root tag and ancestry endpoints and rejects candidate collisions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    const base_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(base_output);
    const base_oid = try testOutputLine(base_output);

    try runTestGit(io, tmp.dir, &.{ "git", "switch", "-c", "feature" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\nparent\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "parent" });
    const parent_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(parent_output);
    const parent_oid = try testOutputLine(parent_output);
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\nparent\nhead\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });
    const head_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_output);
    const head_oid = try testOutputLine(head_output);
    try runTestGit(io, tmp.dir, &.{ "git", "tag", "lightweight", "HEAD" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "tag", "-a", "annotated", "-m", "annotated", "HEAD" });

    const root_contents = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{base_oid});
    defer std.testing.allocator.free(root_contents);
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/ROOTTEST", .data = root_contents });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };

    const abbreviated = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = base_oid,
        .head = head_oid[0..12],
    }));
    try std.testing.expectEqualStrings(head_oid, abbreviated.head_oid.slice());
    var uppercase_base: [64]u8 = undefined;
    const uppercase_slice = uppercase_base[0..base_oid.len];
    _ = std.ascii.upperString(uppercase_slice, base_oid);
    const uppercase = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = uppercase_slice,
        .head = head_oid,
    }));
    try std.testing.expectEqualStrings(base_oid, uppercase.base_oid.slice());

    const short_ref = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "main",
        .head = "feature",
    }));
    try std.testing.expectEqualStrings(base_oid, short_ref.base_oid.slice());
    try std.testing.expectEqualStrings(head_oid, short_ref.head_oid.slice());

    const root_ref_target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "ROOTTEST",
        .head = "HEAD",
    }));
    try std.testing.expectEqualStrings(base_oid, root_ref_target.base_oid.slice());
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/BADSYM", .data = "ref: refs/heads/bad^\n" });
    const malformed_symbolic_root = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "BADSYM",
        .head = "HEAD",
    });
    try std.testing.expectEqual(TargetResolutionFailure.git_command_failed, malformed_symbolic_root.failure);

    const tag_target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "refs/heads/main",
        .head = "annotated^{commit}",
    }));
    try std.testing.expectEqualStrings(head_oid, tag_target.head_oid.slice());
    const auto_peeled_tag = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "refs/heads/main",
        .head = "annotated",
    }));
    try std.testing.expectEqualStrings(head_oid, auto_peeled_tag.head_oid.slice());
    const lightweight_target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "main",
        .head = "lightweight^{}",
    }));
    try std.testing.expectEqualStrings(head_oid, lightweight_target.head_oid.slice());

    const ancestry_target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "HEAD^^",
        .head = "HEAD^",
    }));
    try std.testing.expectEqualStrings(base_oid, ancestry_target.base_oid.slice());
    try std.testing.expectEqualStrings(parent_oid, ancestry_target.head_oid.slice());

    try runTestGit(io, tmp.dir, &.{ "git", "update-ref", "refs/heads/v1.2-3-gabcdef", base_oid });
    const describe_named_ref = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "v1.2-3-gabcdef",
        .head = "HEAD",
    }));
    try std.testing.expectEqualStrings(base_oid, describe_named_ref.base_oid.slice());
    try runTestGit(io, tmp.dir, &.{ "git", "update-ref", "-d", "refs/heads/v1.2-3-gabcdef" });
    const describe_without_ref = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "v1.2-3-gabcdef",
        .head = "HEAD",
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_unresolved, describe_without_ref.failure);

    try runTestGit(io, tmp.dir, &.{ "git", "branch", "collision", "main" });
    try runTestGit(io, tmp.dir, &.{ "git", "tag", "collision", "HEAD" });
    const ref_collision = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "collision",
        .head = "HEAD",
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_ambiguous, ref_collision.failure);

    const object_atom = base_oid[0..7];
    const object_ref = try std.fmt.allocPrint(std.testing.allocator, "refs/heads/{s}", .{object_atom});
    defer std.testing.allocator.free(object_ref);
    try runTestGit(io, tmp.dir, &.{ "git", "update-ref", object_ref, base_oid });
    const root_object_contents = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{base_oid});
    defer std.testing.allocator.free(root_object_contents);
    const root_object_path = try std.fmt.allocPrint(std.testing.allocator, ".git/{s}", .{object_atom});
    defer std.testing.allocator.free(root_object_path);
    try tmp.dir.writeFile(io, .{ .sub_path = root_object_path, .data = root_object_contents });
    const object_collision = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = object_atom,
        .head = "HEAD",
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_ambiguous, object_collision.failure);

    const merge_heads = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n", .{ base_oid, head_oid });
    defer std.testing.allocator.free(merge_heads);
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/MERGE_HEAD", .data = merge_heads });
    const pseudo_collision = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "MERGE_HEAD",
        .head = "HEAD",
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_ambiguous, pseudo_collision.failure);

    try tmp.dir.createDirPath(io, ".git/worktrees/fake");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/worktrees/fake/HEAD", .data = root_contents });
    const slash_guard = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "worktrees/fake/HEAD",
        .head = "HEAD",
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_unresolved, slash_guard.failure);

    const blob_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD:file.txt" });
    defer std.testing.allocator.free(blob_output);
    const blob_oid = try testOutputLine(blob_output);
    const non_commit = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = blob_oid,
        .head = "HEAD",
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_non_commit_object, non_commit.failure);
    const missing = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "ffffffffffffffffffffffffffffffffffffffff",
        .head = "HEAD",
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_unresolved, missing.failure);

    var seen = [_]u32{std.math.maxInt(u32)} ** 65536;
    var collision_first: ?u32 = null;
    var collision_second: ?u32 = null;
    var collision_prefix: [2]u8 = undefined;
    for (0..4096) |index| {
        var content_buffer: [64]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buffer, "collision-{d}", .{index});
        var header_buffer: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buffer, "blob {d}\x00", .{content.len});
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(header);
        hasher.update(content);
        var digest: [20]u8 = undefined;
        hasher.final(&digest);
        const slot = (@as(usize, digest[0]) << 8) | digest[1];
        if (seen[slot] != std.math.maxInt(u32)) {
            collision_first = seen[slot];
            collision_second = @intCast(index);
            collision_prefix = digest[0..2].*;
            break;
        }
        seen[slot] = @intCast(index);
    }
    const first_index = collision_first orelse return error.ExpectedShortOidCollision;
    const second_index = collision_second.?;
    const first_content = try std.fmt.allocPrint(std.testing.allocator, "collision-{d}", .{first_index});
    defer std.testing.allocator.free(first_content);
    const second_content = try std.fmt.allocPrint(std.testing.allocator, "collision-{d}", .{second_index});
    defer std.testing.allocator.free(second_content);
    try tmp.dir.writeFile(io, .{ .sub_path = "collision-a", .data = first_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "collision-b", .data = second_content });
    try runTestGit(io, tmp.dir, &.{ "git", "hash-object", "-w", "collision-a", "collision-b" });
    const collision_hex = std.fmt.bytesToHex(collision_prefix, .lower);
    const short_oid_collision = try resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = &collision_hex,
        .head = "HEAD",
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_ambiguous, short_oid_collision.failure);
}

test "resolver supports sha256 repositories and separates no and multiple merge bases" {
    const io = std.testing.io;
    var sha256_tmp = std.testing.tmpDir(.{});
    defer sha256_tmp.cleanup();
    try runTestGit(io, sha256_tmp.dir, &.{ "git", "init", "--object-format=sha256", "--initial-branch=main" });
    try sha256_tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "sha256\n" });
    try runTestGit(io, sha256_tmp.dir, &.{ "git", "add", "file" });
    try runTestGit(io, sha256_tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "sha256" });
    var sha256_environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer sha256_environment.deinit();
    const sha256_context: git_command.DirectoryContext = .{ .cwd = sha256_tmp.dir, .environment = &sha256_environment };
    const sha256_target = try expectTarget(try resolveTarget(std.testing.allocator, io, sha256_context, .{
        .source_kind = .branch_range,
        .base = "refs/heads/main",
        .head = "HEAD",
    }));
    try std.testing.expectEqual(ObjectFormat.sha256, sha256_target.object_format);
    try std.testing.expectEqual(@as(u8, 64), sha256_target.head_oid.len);

    var graph_tmp = std.testing.tmpDir(.{});
    defer graph_tmp.cleanup();
    try runTestGit(io, graph_tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try graph_tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "graph\n" });
    try runTestGit(io, graph_tmp.dir, &.{ "git", "add", "file" });
    try runTestGit(io, graph_tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "root" });
    const root_output = try testGitOutput(io, graph_tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(root_output);
    const root_oid = try testOutputLine(root_output);
    const tree_output = try testGitOutput(io, graph_tmp.dir, &.{ "git", "rev-parse", "HEAD^{tree}" });
    defer std.testing.allocator.free(tree_output);
    const tree_oid = try testOutputLine(tree_output);
    const orphan_output = try testGitOutput(io, graph_tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-m", "orphan" });
    defer std.testing.allocator.free(orphan_output);
    const orphan_oid = try testOutputLine(orphan_output);

    var graph_environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer graph_environment.deinit();
    const graph_context: git_command.DirectoryContext = .{ .cwd = graph_tmp.dir, .environment = &graph_environment };
    const no_merge = try resolveTarget(std.testing.allocator, io, graph_context, .{
        .source_kind = .branch_range,
        .base = root_oid,
        .head = orphan_oid,
    });
    try std.testing.expectEqual(TargetResolutionFailure.no_merge_base, no_merge.failure);

    const a1_output = try testGitOutput(io, graph_tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-p", root_oid, "-m", "a1" });
    defer std.testing.allocator.free(a1_output);
    const a1 = try testOutputLine(a1_output);
    const b1_output = try testGitOutput(io, graph_tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-p", root_oid, "-m", "b1" });
    defer std.testing.allocator.free(b1_output);
    const b1 = try testOutputLine(b1_output);
    const a2_output = try testGitOutput(io, graph_tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-p", a1, "-p", b1, "-m", "a2" });
    defer std.testing.allocator.free(a2_output);
    const a2 = try testOutputLine(a2_output);
    const b2_output = try testGitOutput(io, graph_tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-p", b1, "-p", a1, "-m", "b2" });
    defer std.testing.allocator.free(b2_output);
    const b2 = try testOutputLine(b2_output);
    const multiple = try resolveTarget(std.testing.allocator, io, graph_context, .{
        .source_kind = .branch_range,
        .base = a2,
        .head = b2,
    });
    try std.testing.expectEqual(TargetResolutionFailure.ambiguous_merge_base, multiple.failure);
}

test "resolver keeps endpoint OIDs pinned when refs move before merge-base" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "base\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    const base_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(base_output);
    const base_oid = try testOutputLine(base_output);
    try runTestGit(io, tmp.dir, &.{ "git", "switch", "-c", "feature" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "head\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });
    const head_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_output);
    const head_oid = try testOutputLine(head_output);

    var movement: RefMovementTestContext = .{
        .base_ref = "refs/heads/main",
        .new_base_oid = head_oid,
        .head_ref = "refs/heads/feature",
        .new_head_oid = base_oid,
    };
    const hooks: TargetResolutionTestHooks = .{
        .after_endpoints_context = &movement,
        .after_endpoints = RefMovementTestContext.move,
    };
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const target = try expectTarget(try resolveTargetWithHooks(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "refs/heads/main",
        .head = "refs/heads/feature",
    }, &hooks));
    try std.testing.expectEqualStrings(base_oid, target.base_oid.slice());
    try std.testing.expectEqualStrings(head_oid, target.head_oid.slice());
    try std.testing.expectEqualStrings(base_oid, target.diff_base_oid.slice());
}
