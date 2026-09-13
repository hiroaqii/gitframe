//! Strict cross-file Review Run admission with terminal-result precedence.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const strict = @import("../committed_review/strict_json.zig");
const capability = @import("capability.zig");
const store_name = @import("name.zig");
const store_path = @import("path.zig");

pub const max_scan_artifact_bytes: usize = 256 * 1024 * 1024;
pub const max_location_bytes: usize = 512;

pub const LocationRecord = struct {
    review_repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    directory_name: store_name.RunDirectoryName,
};

pub const LocationSnapshot = struct {
    record: LocationRecord,
    metadata: capability.Metadata,
    digest: committed_review.Sha256Digest,

    pub fn eql(left: LocationSnapshot, right: LocationSnapshot) bool {
        return left.record.review_repository_id.eql(right.record.review_repository_id) and
            left.record.review_id.eql(right.record.review_id) and
            left.record.directory_name.eql(&right.record.directory_name) and
            left.metadata.sameObject(right.metadata) and left.metadata.size == right.metadata.size and
            left.digest.eql(right.digest);
    }
};

pub const RunLocationSnapshot = struct {
    location: LocationSnapshot,
    run_metadata: capability.Metadata,

    pub fn eql(left: RunLocationSnapshot, right: RunLocationSnapshot) bool {
        return left.location.eql(right.location) and
            left.run_metadata.sameObject(right.run_metadata);
    }
};

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
    run_location: ?RunLocationSnapshot = null,

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
            .run_location = loaded.run_location,
        };
    }

    pub fn eql(left: ArtifactSnapshot, right: ArtifactSnapshot) bool {
        return left.manifest_digest.eql(right.manifest_digest) and
            left.findings_digest.eql(right.findings_digest) and
            left.draft_state == right.draft_state and
            optionalDigestEql(left.draft_digest, right.draft_digest) and
            optionalDigestEql(left.result_digest, right.result_digest) and
            optionalLocationEql(left.run_location, right.run_location);
    }
};

fn optionalLocationEql(left: ?RunLocationSnapshot, right: ?RunLocationSnapshot) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.eql(right.?);
}

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
    run_location: RunLocationSnapshot,

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
    location_invalid,
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

pub const LocationReadResult = union(enum) {
    absent,
    location: LocationSnapshot,
    invalid: InvalidReason,
};

pub fn writeLocationCanonicalAlloc(
    allocator: std.mem.Allocator,
    record: LocationRecord,
) strict.ParseError![]u8 {
    const directory_name = store_name.RunDirectoryName.fromStored(
        record.directory_name.slice(),
        record.review_id,
    ) catch return error.InvalidValue;
    const storage = try allocator.alloc(u8, max_location_bytes);
    errdefer allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch return error.ArtifactTooLarge;
    stringify.objectField("schema_version") catch return error.ArtifactTooLarge;
    stringify.write(@as(u64, 1)) catch return error.ArtifactTooLarge;
    stringify.objectField("review_repository_id") catch return error.ArtifactTooLarge;
    const repository_id = record.review_repository_id.canonical();
    stringify.write(&repository_id) catch return error.ArtifactTooLarge;
    stringify.objectField("review_id") catch return error.ArtifactTooLarge;
    const review_id = record.review_id.canonical();
    stringify.write(&review_id) catch return error.ArtifactTooLarge;
    stringify.objectField("directory_name") catch return error.ArtifactTooLarge;
    stringify.write(directory_name.slice()) catch return error.ArtifactTooLarge;
    stringify.endObject() catch return error.ArtifactTooLarge;
    writer.writeByte('\n') catch return error.ArtifactTooLarge;
    return try allocator.realloc(storage, writer.buffered().len);
}

pub fn parseLocationStrict(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) strict.ParseError!LocationRecord {
    if (bytes.len == 0 or bytes.len > max_location_bytes) return error.ArtifactTooLarge;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parser = strict.Parser.init(arena.allocator(), bytes);
    defer parser.deinit();
    try parser.beginObject();
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var repository_id: ?committed_review.ReviewRepositoryId = null;
    var review_id: ?committed_review.ReviewId = null;
    var raw_directory_name: ?[]const u8 = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            try strict.markSeen(&seen, 0);
            schema_version = try parser.unsigned(u64);
        } else if (std.mem.eql(u8, key, "review_repository_id")) {
            try strict.markSeen(&seen, 1);
            repository_id = committed_review.ReviewRepositoryId.parse(try parser.string()) catch
                return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "review_id")) {
            try strict.markSeen(&seen, 2);
            review_id = committed_review.ReviewId.parse(try parser.string()) catch
                return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "directory_name")) {
            try strict.markSeen(&seen, 3);
            raw_directory_name = try parser.string();
        } else {
            return error.UnknownField;
        }
    }
    try strict.requireFields(seen, 0b1111);
    if (schema_version.? != 1) return error.UnsupportedSchemaVersion;
    const directory_name = store_name.RunDirectoryName.fromStored(
        raw_directory_name.?,
        review_id.?,
    ) catch return error.InvalidValue;
    try parser.endDocument();
    const record: LocationRecord = .{
        .review_repository_id = repository_id.?,
        .review_id = review_id.?,
        .directory_name = directory_name,
    };
    const canonical = try writeLocationCanonicalAlloc(allocator, record);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) return error.InvalidValue;
    return record;
}

pub fn readLocation(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    budget: ?*ArtifactBudget,
) std.mem.Allocator.Error!LocationReadResult {
    const location_name = store_path.RunLocationName.format(review_id);
    const metadata = namespace.admitChild(location_name.slice(), .regular_file) catch |err|
        return locationReadError(err);
    if (budget) |value| value.consume(metadata.size) catch
        return .{ .invalid = .scan_artifact_bytes_exceeded };
    const bytes = namespace.readRegularAlloc(
        allocator,
        io,
        location_name.slice(),
        max_location_bytes,
    ) catch |err| return locationReadError(err);
    defer allocator.free(bytes);
    if (bytes.len != metadata.size) return .{ .invalid = .location_invalid };
    const record = parseLocationStrict(allocator, bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .invalid = .location_invalid };
    };
    if (!record.review_repository_id.eql(repository_id) or !record.review_id.eql(review_id)) {
        return .{ .invalid = .identity_mismatch };
    }
    return .{ .location = .{
        .record = record,
        .metadata = metadata,
        .digest = committed_review.Sha256Digest.hash(bytes),
    } };
}

fn locationReadError(err: anyerror) LocationReadResult {
    return switch (err) {
        error.FileNotFound => .absent,
        error.AccessDenied, error.PermissionDenied => .{ .invalid = .permission_denied },
        error.WrongType,
        error.WrongOwner,
        error.WrongMode,
        error.CrossDevice,
        error.MultipleLinks,
        error.SymLinkLoop,
        error.NotDir,
        error.FileSizeOutOfBounds,
        error.FileChangedWhileReading,
        => .{ .invalid = .location_invalid },
        else => .{ .invalid = .io_failed },
    };
}

pub fn loadValidated(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    budget: *ArtifactBudget,
) std.mem.Allocator.Error!LoadResult {
    const location_result = try readLocation(allocator, io, namespace, repository_id, review_id, budget);
    const location = switch (location_result) {
        .location => |value| value,
        .absent => return .{ .invalid = .run_missing_or_unsafe },
        .invalid => |reason| return .{ .invalid = reason },
    };
    return loadValidatedAt(allocator, io, namespace, location, budget);
}

fn loadValidatedAt(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    location: LocationSnapshot,
    budget: *ArtifactBudget,
) std.mem.Allocator.Error!LoadResult {
    const repository_id = location.record.review_repository_id;
    const review_id = location.record.review_id;
    var run_dir = namespace.openDirectory(location.record.directory_name.slice()) catch |err|
        return mapReadErrorAs(err, .run_missing_or_unsafe);
    defer run_dir.deinit();
    const initial_run_metadata = run_dir.metadata;

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

    const current_run = namespace.admitChild(location.record.directory_name.slice(), .directory) catch |err|
        return mapReadErrorAs(err, .run_missing_or_unsafe);
    if (!current_run.sameObject(initial_run_metadata)) return .{ .invalid = .identity_mismatch };
    const current_location = switch (try readLocation(allocator, io, namespace, repository_id, review_id, null)) {
        .location => |value| value,
        .absent => return .{ .invalid = .location_invalid },
        .invalid => |reason| return .{ .invalid = reason },
    };
    if (!current_location.eql(location)) return .{ .invalid = .identity_mismatch };

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
        .run_location = .{ .location = location, .run_metadata = initial_run_metadata },
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

test "review run location record is strict canonical schema one" {
    const allocator = std.testing.allocator;
    const repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const review_id = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const directory_name = try store_name.RunDirectoryName.fromStored(
        "20260913-1942-Feature-API-223e4567",
        review_id,
    );
    const bytes = try writeLocationCanonicalAlloc(allocator, .{
        .review_repository_id = repository_id,
        .review_id = review_id,
        .directory_name = directory_name,
    });
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"review_id\":\"223e4567-e89b-42d3-a456-426614174000\",\"directory_name\":\"20260913-1942-Feature-API-223e4567\"}\n",
        bytes,
    );
    const parsed = try parseLocationStrict(allocator, bytes);
    try std.testing.expect(parsed.review_repository_id.eql(repository_id));
    try std.testing.expect(parsed.review_id.eql(review_id));
    try std.testing.expect(parsed.directory_name.eql(&directory_name));

    try std.testing.expectError(error.UnsupportedSchemaVersion, parseLocationStrict(allocator, "{\"schema_version\":2,\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"review_id\":\"223e4567-e89b-42d3-a456-426614174000\",\"directory_name\":\"20260913-1942-Feature-API-223e4567\"}\n"));
    try std.testing.expectError(error.MissingField, parseLocationStrict(allocator, "{\"schema_version\":1,\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"review_id\":\"223e4567-e89b-42d3-a456-426614174000\"}\n"));
    try std.testing.expectError(error.InvalidValue, parseLocationStrict(allocator, "{\"schema_version\":1,\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"review_id\":\"223e4567-e89b-42d3-a456-426614174000\",\"directory_name\":\"20260913-1942-Feature-API-deadbeef\"}\n"));
    try std.testing.expectError(error.InvalidValue, parseLocationStrict(allocator, "{\"review_id\":\"223e4567-e89b-42d3-a456-426614174000\",\"schema_version\":1,\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"directory_name\":\"20260913-1942-Feature-API-223e4567\"}\n"));
    try std.testing.expectError(error.UnknownField, parseLocationStrict(allocator, "{\"schema_version\":1,\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"review_id\":\"223e4567-e89b-42d3-a456-426614174000\",\"directory_name\":\"20260913-1942-Feature-API-223e4567\",\"extra\":true}\n"));
}

test "review history backend run state gives valid result terminal precedence" {
    try std.testing.expectEqual(committed_review.ReviewRunState.completed, committed_review.ReviewRunState.derive(false, true));
    try std.testing.expectEqual(committed_review.ReviewRunState.completed, committed_review.ReviewRunState.derive(true, true));
    try std.testing.expectEqual(committed_review.ReviewRunState.draft, committed_review.ReviewRunState.derive(true, false));
    try std.testing.expectEqual(committed_review.ReviewRunState.new, committed_review.ReviewRunState.derive(false, false));
}
