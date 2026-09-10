//! Strict cross-file Review Run admission with terminal-result precedence.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const capability = @import("capability.zig");

pub const max_scan_artifact_bytes: usize = 256 * 1024 * 1024;

pub const ArtifactBudget = struct {
    used: usize = 0,

    pub fn consume(self: *ArtifactBudget, amount: u64) error{ScanArtifactBytesExceeded}!void {
        const value = std.math.cast(usize, amount) orelse return error.ScanArtifactBytesExceeded;
        self.used = std.math.add(usize, self.used, value) catch return error.ScanArtifactBytesExceeded;
        if (self.used > max_scan_artifact_bytes) return error.ScanArtifactBytesExceeded;
    }
};

pub const RetainedDraftDiagnostic = enum { unsafe, invalid };

pub const DraftSnapshotState = enum { absent, valid, invalid, unsafe };

/// Exact scan-time artifact identity carried by a row and required again at
/// selection. It contains no path and grants no write authority.
pub const ArtifactSnapshot = struct {
    manifest_digest: committed_review.Sha256Digest,
    findings_digest: committed_review.Sha256Digest,
    draft_state: DraftSnapshotState,
    draft_digest: ?committed_review.Sha256Digest,
    result_digest: ?committed_review.Sha256Digest,

    pub fn fromLoaded(loaded: *const LoadedRunArtifacts) ArtifactSnapshot {
        return .{
            .manifest_digest = committed_review.Sha256Digest.hash(loaded.manifest_bytes),
            .findings_digest = committed_review.Sha256Digest.hash(loaded.findings_bytes),
            .draft_state = if (loaded.draft != null)
                .valid
            else if (loaded.retained_draft_diagnostic == .invalid)
                .invalid
            else if (loaded.retained_draft_diagnostic == .unsafe)
                .unsafe
            else if (loaded.draft_bytes != null)
                .invalid
            else
                .absent,
            .draft_digest = if (loaded.draft_bytes) |bytes| committed_review.Sha256Digest.hash(bytes) else null,
            .result_digest = if (loaded.result_bytes) |bytes| committed_review.Sha256Digest.hash(bytes) else null,
        };
    }

    pub fn eql(left: ArtifactSnapshot, right: ArtifactSnapshot) bool {
        return left.manifest_digest.eql(right.manifest_digest) and
            left.findings_digest.eql(right.findings_digest) and
            left.draft_state == right.draft_state and
            optionalDigestEql(left.draft_digest, right.draft_digest) and
            optionalDigestEql(left.result_digest, right.result_digest);
    }
};

fn optionalDigestEql(
    left: ?committed_review.Sha256Digest,
    right: ?committed_review.Sha256Digest,
) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.eql(right.?);
}

pub const LoadedRunArtifacts = struct {
    manifest_bytes: []u8,
    findings_bytes: []u8,
    draft_bytes: ?[]u8,
    result_bytes: ?[]u8,
    manifest: committed_review.codec.Parsed(committed_review.ReviewRunManifest),
    findings: committed_review.codec.Parsed(committed_review.FindingSet),
    draft: ?committed_review.codec.Parsed(committed_review.ReviewDraftState),
    result: ?committed_review.codec.Parsed(committed_review.RevisionReviewResult),
    state: committed_review.ReviewRunState,
    created_at_unix: i64,
    retained_draft_diagnostic: ?RetainedDraftDiagnostic,

    pub fn deinit(self: *LoadedRunArtifacts, allocator: std.mem.Allocator) void {
        if (self.result) |*value| value.deinit();
        if (self.draft) |*value| value.deinit();
        self.findings.deinit();
        self.manifest.deinit();
        if (self.result_bytes) |bytes| allocator.free(bytes);
        if (self.draft_bytes) |bytes| allocator.free(bytes);
        allocator.free(self.findings_bytes);
        allocator.free(self.manifest_bytes);
        self.* = undefined;
    }
};

pub const InvalidReason = enum {
    run_missing_or_unsafe,
    unknown_run_entry,
    immutable_file_invalid,
    artifact_invalid,
    identity_mismatch,
    draft_invalid,
    result_invalid,
    scan_artifact_bytes_exceeded,
    enumeration_failed,
    permission_denied,
    io_failed,
};

pub const LoadResult = union(enum) {
    loaded: LoadedRunArtifacts,
    invalid: InvalidReason,

    pub fn deinit(self: *LoadResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .loaded => |*value| value.deinit(allocator),
            .invalid => {},
        }
        self.* = .{ .invalid = .artifact_invalid };
    }
};

pub fn loadValidated(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    budget: *ArtifactBudget,
) std.mem.Allocator.Error!LoadResult {
    const review_text = review_id.canonical();
    var run_dir = namespace.openDirectory(&review_text) catch |err| return mapReadErrorAs(err, .run_missing_or_unsafe);
    defer run_dir.deinit();

    const entries = enumerateAuthorityEntries(io, run_dir) catch |err|
        return mapReadErrorAs(err, if (err == error.UnknownRunEntry) .unknown_run_entry else .enumeration_failed);
    if (!entries.manifest or !entries.findings) return .{ .invalid = .immutable_file_invalid };

    var manifest_bytes: ?[]u8 = null;
    var findings_bytes: ?[]u8 = null;
    var manifest: ?committed_review.codec.Parsed(committed_review.ReviewRunManifest) = null;
    var findings: ?committed_review.codec.Parsed(committed_review.FindingSet) = null;
    var draft_bytes: ?[]u8 = null;
    var parsed_draft: ?committed_review.codec.Parsed(committed_review.ReviewDraftState) = null;
    var result_bytes: ?[]u8 = null;
    var parsed_result: ?committed_review.codec.Parsed(committed_review.RevisionReviewResult) = null;
    var transferred = false;
    defer if (!transferred) {
        if (parsed_result) |*value| value.deinit();
        if (parsed_draft) |*value| value.deinit();
        if (findings) |*value| value.deinit();
        if (manifest) |*value| value.deinit();
        if (result_bytes) |bytes| allocator.free(bytes);
        if (draft_bytes) |bytes| allocator.free(bytes);
        if (findings_bytes) |bytes| allocator.free(bytes);
        if (manifest_bytes) |bytes| allocator.free(bytes);
    };

    manifest_bytes = readAuthority(
        allocator,
        io,
        run_dir,
        "manifest.json",
        committed_review.limits.max_manifest_bytes,
        budget,
    ) catch |err| return mapReadError(err);
    findings_bytes = readAuthority(
        allocator,
        io,
        run_dir,
        "findings.json",
        committed_review.limits.max_artifact_bytes,
        budget,
    ) catch |err| return mapReadError(err);

    manifest = committed_review.ReviewRunManifest.parseStrict(allocator, manifest_bytes.?) catch
        return .{ .invalid = .artifact_invalid };
    findings = committed_review.FindingSet.parseStrict(allocator, findings_bytes.?) catch
        return .{ .invalid = .artifact_invalid };
    manifest.?.value.validateFindingSet(findings_bytes.?, &findings.?.value) catch
        return .{ .invalid = .artifact_invalid };
    if (!manifest.?.value.review_id.eql(review_id) or
        !manifest.?.value.review_repository_id.eql(repository_id))
    {
        return .{ .invalid = .identity_mismatch };
    }
    const created_at_unix = committed_review.strict_json.timestampToUnixSeconds(manifest.?.value.created_at) catch
        return .{ .invalid = .artifact_invalid };

    var retained_draft_diagnostic: ?RetainedDraftDiagnostic = null;

    if (entries.result) {
        result_bytes = readAuthority(
            allocator,
            io,
            run_dir,
            "result.json",
            committed_review.limits.max_artifact_bytes,
            budget,
        ) catch |err| return mapReadErrorAs(err, .result_invalid);
        parsed_result = committed_review.RevisionReviewResult.parseStrict(allocator, result_bytes.?) catch
            return .{ .invalid = .result_invalid };
        parsed_result.?.value.validateAgainst(&findings.?.value, manifest.?.value.findings_digest) catch
            return .{ .invalid = .result_invalid };

        if (entries.draft) {
            // A completed Run never needs retained draft authority. Unsafe or
            // malformed retained evidence is diagnostic-only.
            if (run_dir.admitChild("review_state.json", .regular_file)) |metadata| {
                // Keep empty invalid evidence in the exact snapshot too.
                draft_bytes = if (metadata.size == 0) try allocator.dupe(u8, "") else readAuthority(
                    allocator,
                    io,
                    run_dir,
                    "review_state.json",
                    committed_review.limits.max_artifact_bytes,
                    budget,
                ) catch |err| blk: {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    if (err == error.ScanArtifactBytesExceeded) {
                        return .{ .invalid = .scan_artifact_bytes_exceeded };
                    }
                    const classified = try mapReadErrorAs(err, .draft_invalid);
                    if (classified.invalid == .permission_denied or classified.invalid == .io_failed) return classified;
                    retained_draft_diagnostic = .invalid;
                    break :blk null;
                };
                if (draft_bytes) |bytes| {
                    parsed_draft = committed_review.ReviewDraftState.parseStrict(allocator, bytes) catch null;
                    if (parsed_draft) |*draft| {
                        draft.value.validateAgainst(&findings.?.value, manifest.?.value.findings_digest) catch {
                            draft.deinit();
                            parsed_draft = null;
                        };
                    }
                    if (parsed_draft == null) retained_draft_diagnostic = .invalid;
                }
            } else |_| {
                retained_draft_diagnostic = .unsafe;
            }
        }
    } else if (entries.draft) {
        draft_bytes = readAuthority(
            allocator,
            io,
            run_dir,
            "review_state.json",
            committed_review.limits.max_artifact_bytes,
            budget,
        ) catch |err| return mapReadErrorAs(err, .draft_invalid);
        parsed_draft = committed_review.ReviewDraftState.parseStrict(allocator, draft_bytes.?) catch
            return .{ .invalid = .draft_invalid };
        parsed_draft.?.value.validateAgainst(&findings.?.value, manifest.?.value.findings_digest) catch
            return .{ .invalid = .draft_invalid };
    }

    transferred = true;
    return .{ .loaded = .{
        .manifest_bytes = manifest_bytes.?,
        .findings_bytes = findings_bytes.?,
        .draft_bytes = draft_bytes,
        .result_bytes = result_bytes,
        .manifest = manifest.?,
        .findings = findings.?,
        .draft = parsed_draft,
        .result = parsed_result,
        .state = committed_review.ReviewRunState.derive(parsed_draft != null, parsed_result != null),
        .created_at_unix = created_at_unix,
        .retained_draft_diagnostic = retained_draft_diagnostic,
    } };
}

const AuthorityEntries = struct {
    manifest: bool = false,
    findings: bool = false,
    draft: bool = false,
    result: bool = false,
};

fn enumerateAuthorityEntries(io: std.Io, run_dir: capability.DirectoryCapability) !AuthorityEntries {
    var result: AuthorityEntries = .{};
    var iterator = run_dir.iterate();
    while (try iterator.next(run_dir, io)) |entry| {
        if (std.mem.eql(u8, entry.name, "manifest.json")) {
            result.manifest = true;
        } else if (std.mem.eql(u8, entry.name, "findings.json")) {
            result.findings = true;
        } else if (std.mem.eql(u8, entry.name, "review_state.json")) {
            result.draft = true;
        } else if (std.mem.eql(u8, entry.name, "result.json")) {
            result.result = true;
        } else {
            return error.UnknownRunEntry;
        }
    }
    return result;
}

fn readAuthority(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: capability.DirectoryCapability,
    name: []const u8,
    maximum: usize,
    budget: *ArtifactBudget,
) ![]u8 {
    const metadata = try directory.admitChild(name, .regular_file);
    try budget.consume(metadata.size);
    const bytes = try directory.readRegularAlloc(allocator, io, name, maximum);
    if (bytes.len != metadata.size) {
        allocator.free(bytes);
        return error.FileChangedWhileReading;
    }
    return bytes;
}

fn mapReadError(err: anyerror) std.mem.Allocator.Error!LoadResult {
    return mapReadErrorAs(err, .immutable_file_invalid);
}

fn mapReadErrorAs(err: anyerror, reason: InvalidReason) std.mem.Allocator.Error!LoadResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .invalid = switch (err) {
        error.ScanArtifactBytesExceeded => .scan_artifact_bytes_exceeded,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.FileNotFound,
        error.WrongType,
        error.WrongOwner,
        error.WrongMode,
        error.CrossDevice,
        error.MultipleLinks,
        error.SymLinkLoop,
        error.NotDir,
        error.FileSizeOutOfBounds,
        error.FileChangedWhileReading,
        error.UnknownRunEntry,
        => reason,
        else => .io_failed,
    } };
}

test "review history backend artifact budget is aggregate and fail closed" {
    var budget: ArtifactBudget = .{ .used = max_scan_artifact_bytes - 1 };
    try budget.consume(1);
    try std.testing.expectError(error.ScanArtifactBytesExceeded, budget.consume(1));
}

test "review history backend run state gives valid result terminal precedence" {
    try std.testing.expectEqual(committed_review.ReviewRunState.completed, committed_review.ReviewRunState.derive(false, true));
    try std.testing.expectEqual(committed_review.ReviewRunState.completed, committed_review.ReviewRunState.derive(true, true));
    try std.testing.expectEqual(committed_review.ReviewRunState.draft, committed_review.ReviewRunState.derive(true, false));
    try std.testing.expectEqual(committed_review.ReviewRunState.new, committed_review.ReviewRunState.derive(false, false));
}
