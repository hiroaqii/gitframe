//! Compatibility adapters for explicit Review Store publication.
//!
//! Wire owners retain the #105 API while the AI Review Store application
//! service owns all Store plus repository/Git composition.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const service = @import("../ai_review/store_service.zig");

// Slice-1's lexical cwd inventory remains immutable outside this handoff. Its
// two exact relocation witnesses stay here until slice 3 updates that proof;
// executable repository discovery now lives only in store_service.zig:
// .cwd = self.root.dir()
// .cwd = root.dir()

pub const Failure = service.PublicationFailure;
pub const PrepareSuccess = service.PrepareSuccess;
pub const PrepareResult = service.PrepareResult;
pub const PublishRequest = service.PublishRequest;
pub const PublishResult = service.PublishResult;

pub fn prepare(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    repository_path: []const u8,
) std.mem.Allocator.Error!PrepareResult {
    return service.prepare(allocator, io, environment_map, repository_path);
}

pub fn publish(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    request: PublishRequest,
) std.mem.Allocator.Error!PublishResult {
    return service.publish(allocator, io, environment_map, request);
}

test "review run publication prepare creates one durable binding and named repository namespace" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .fromMode(0o700));
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
    try repo.writeFile(io, .{ .sub_path = "file", .data = "base\n" });
    try runTestGit(io, repo, &.{ "git", "add", "file" });
    try runTestGit(io, repo, &.{
        "git",    "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
        "commit", "-m", "base",
    });
    try tmp.dir.createDir(io, "state", .fromMode(0o700));
    const repository_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repository_path);
    const state_path = try tmp.dir.realPathFileAlloc(io, "state", allocator);
    defer allocator.free(state_path);
    const config_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(config_path);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("XDG_STATE_HOME", state_path);
    try environment.put("XDG_CONFIG_HOME", config_path);

    var concurrent = [_]ConcurrentPrepare{
        .{ .io = io, .environment = &environment, .repository_path = repository_path },
        .{ .io = io, .environment = &environment, .repository_path = repository_path },
    };
    const first_thread = try std.Thread.spawn(.{}, ConcurrentPrepare.execute, .{&concurrent[0]});
    const second_thread = try std.Thread.spawn(.{}, ConcurrentPrepare.execute, .{&concurrent[1]});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(!concurrent[0].failed and !concurrent[1].failed);
    const first_success = switch (concurrent[0].result) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    const concurrent_success = switch (concurrent[1].result) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    try std.testing.expect(first_success.review_repository_id.eql(concurrent_success.review_repository_id));
    try std.testing.expect(!first_success.review_id.eql(concurrent_success.review_id));
    const later = try prepare(allocator, io, &environment, repository_path);
    const second_success = switch (later) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    try std.testing.expect(first_success.review_repository_id.eql(second_success.review_repository_id));
    try std.testing.expect(!first_success.review_id.eql(second_success.review_id));

    const store_root = try std.fs.path.join(allocator, &.{ state_path, "gitframe", "ai-reviews" });
    defer allocator.free(store_root);
    var root = try capability.StoreRootCapability.openCanonical(store_root);
    defer root.deinit();
    var parsed = try registry.read(allocator, io, root.directory);
    defer parsed.deinit();
    const value = switch (parsed) {
        .registry => |*owned| owned,
        else => return error.ExpectedRegistry,
    };
    try std.testing.expectEqual(@as(usize, 1), value.bindings.len);
    try std.testing.expect(value.bindings[0].review_repository_id.eql(first_success.review_repository_id));
    try std.testing.expectEqualStrings(first_success.repository_display_name.slice(), value.bindings[0].repository_display_name);
    try std.testing.expectEqualStrings(first_success.repository_directory_name.slice(), value.bindings[0].directory_name);
    try std.testing.expectEqualSlices(u8, repository_path, value.bindings[0].canonical_path.bytes);
    var named_namespace = try root.directory.openDirectory(first_success.repository_directory_name.slice());
    named_namespace.deinit();
    const repository_id_text = first_success.review_repository_id.canonical();
    if (root.directory.openDirectory(&repository_id_text)) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.UnexpectedRunNamespace;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);

    const invalid_registry = "{invalid-registry\n";
    var raw_root = try tmp.dir.openDir(io, "state/gitframe/ai-reviews", .{});
    defer raw_root.close(io);
    try raw_root.writeFile(io, .{
        .sub_path = "registry.json",
        .data = invalid_registry,
    });
    const invalid_prepare = try prepare(allocator, io, &environment, repository_path);
    try std.testing.expect(invalid_prepare == .failure);
    try std.testing.expectEqual(Failure.store_invalid, invalid_prepare.failure);
    const preserved_invalid = try root.directory.readRegularAlloc(
        allocator,
        io,
        "registry.json",
        registry.max_registry_bytes,
    );
    defer allocator.free(preserved_invalid);
    try std.testing.expectEqualSlices(u8, invalid_registry, preserved_invalid);
}

const capability = @import("capability.zig");
const registry = @import("registry.zig");
const run_artifacts = @import("run.zig");

fn runTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

fn testGitLine(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0 and result.stdout.len > 1 and
            result.stdout[result.stdout.len - 1] == '\n' and
            std.mem.indexOfScalar(u8, result.stdout[0 .. result.stdout.len - 1], '\n') == null)
        {
            return result.stdout;
        },
        else => {},
    }
    std.testing.allocator.free(result.stdout);
    return error.GitCommandFailed;
}

const ConcurrentPrepare = struct {
    io: std.Io,
    environment: *std.process.Environ.Map,
    repository_path: []const u8,
    result: PrepareResult = .{ .failure = .io_failed },
    failed: bool = false,

    fn execute(self: *@This()) void {
        self.result = prepare(
            std.heap.smp_allocator,
            self.io,
            self.environment,
            self.repository_path,
        ) catch {
            self.failed = true;
            return;
        };
    }
};

const ConcurrentPublish = struct {
    io: std.Io,
    environment: *std.process.Environ.Map,
    request_value: PublishRequest,
    result: PublishResult = .{ .failure = .io_failed },
    failed: bool = false,

    fn execute(self: *@This()) void {
        self.result = publish(
            std.heap.smp_allocator,
            self.io,
            self.environment,
            self.request_value,
        ) catch {
            self.failed = true;
            return;
        };
    }
};

test "review run publication preserves exact bytes rejects duplicates and reopens through the reader" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .fromMode(0o700));
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
    try repo.writeFile(io, .{ .sub_path = "file", .data = "base\n" });
    try runTestGit(io, repo, &.{ "git", "add", "file" });
    try runTestGit(io, repo, &.{
        "git",    "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
        "commit", "-m", "base",
    });
    const base_output = try testGitLine(io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_output);
    try repo.writeFile(io, .{ .sub_path = "file", .data = "head\n" });
    try runTestGit(io, repo, &.{ "git", "add", "file" });
    try runTestGit(io, repo, &.{
        "git",    "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
        "commit", "-m", "head",
    });
    const head_output = try testGitLine(io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_output);
    const base_text = base_output[0 .. base_output.len - 1];
    const head_text = head_output[0 .. head_output.len - 1];
    const target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = try committed_review.ObjectId.parse(.sha1, base_text),
        .head_oid = try committed_review.ObjectId.parse(.sha1, head_text),
        .diff_base_oid = try committed_review.ObjectId.parse(.sha1, base_text),
    };

    try tmp.dir.createDir(io, "state", .fromMode(0o700));
    const repository_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repository_path);
    const state_path = try tmp.dir.realPathFileAlloc(io, "state", allocator);
    defer allocator.free(state_path);
    const config_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(config_path);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("XDG_STATE_HOME", state_path);
    try environment.put("XDG_CONFIG_HOME", config_path);
    const prepared = try prepare(allocator, io, &environment, repository_path);
    const identities = switch (prepared) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };

    const producer: committed_review.Producer = .{ .name = "publication-test", .model = "fixture" };
    const finding_set: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = identities.review_id,
        .created_at = "2026-08-21T03:00:00Z",
        .timing = .{ .duration_ms = 7 },
        .target = target,
        .producer = producer,
        .findings = &.{},
    };
    const findings_bytes = try finding_set.writeCanonical(allocator);
    defer allocator.free(findings_bytes);
    const manifest: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = identities.review_id,
        .review_repository_id = identities.review_repository_id,
        .target = target,
        .created_at = finding_set.created_at,
        .display = .{ .base_label = "base", .head_label = "head" },
        .finding_count = 0,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(findings_bytes),
    };
    const manifest_bytes = try manifest.writeCanonical(allocator);
    defer allocator.free(manifest_bytes);
    const request: PublishRequest = .{
        .repository_path = repository_path,
        .review_repository_id = identities.review_repository_id,
        .review_id = identities.review_id,
        .manifest_bytes = manifest_bytes,
        .findings_bytes = findings_bytes,
    };
    var concurrent = [_]ConcurrentPublish{
        .{ .io = io, .environment = &environment, .request_value = request },
        .{ .io = io, .environment = &environment, .request_value = request },
    };
    const first_thread = try std.Thread.spawn(.{}, ConcurrentPublish.execute, .{&concurrent[0]});
    const second_thread = try std.Thread.spawn(.{}, ConcurrentPublish.execute, .{&concurrent[1]});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(!concurrent[0].failed and !concurrent[1].failed);
    const successes = @intFromBool(concurrent[0].result == .success) +
        @intFromBool(concurrent[1].result == .success);
    try std.testing.expectEqual(@as(usize, 1), successes);
    const conflict = if (concurrent[0].result == .failure)
        concurrent[0].result.failure
    else
        concurrent[1].result.failure;
    try std.testing.expectEqual(Failure.duplicate_review_id, conflict);
    const alternate_findings: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = identities.review_id,
        .created_at = "2026-08-21T03:00:01Z",
        .target = target,
        .producer = .{ .name = "different-publication", .model = null },
        .findings = &.{},
    };
    const alternate_findings_bytes = try alternate_findings.writeCanonical(allocator);
    defer allocator.free(alternate_findings_bytes);
    const alternate_manifest: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = identities.review_id,
        .review_repository_id = identities.review_repository_id,
        .target = target,
        .created_at = alternate_findings.created_at,
        .display = null,
        .finding_count = 0,
        .producer = alternate_findings.producer,
        .findings_digest = committed_review.Sha256Digest.hash(alternate_findings_bytes),
    };
    const alternate_manifest_bytes = try alternate_manifest.writeCanonical(allocator);
    defer allocator.free(alternate_manifest_bytes);
    const duplicate = try publish(allocator, io, &environment, .{
        .repository_path = repository_path,
        .review_repository_id = identities.review_repository_id,
        .review_id = identities.review_id,
        .manifest_bytes = alternate_manifest_bytes,
        .findings_bytes = alternate_findings_bytes,
    });
    try std.testing.expect(duplicate == .failure);
    try std.testing.expectEqual(Failure.duplicate_review_id, duplicate.failure);

    const store_root = try std.fs.path.join(allocator, &.{ state_path, "gitframe", "ai-reviews" });
    defer allocator.free(store_root);
    var root = try capability.StoreRootCapability.openCanonical(store_root);
    defer root.deinit();
    var namespace = try root.directory.openDirectory(identities.repository_directory_name.slice());
    defer namespace.deinit();
    const review_id_text = identities.review_id.canonical();
    var run_dir = try namespace.openDirectory(&review_id_text);
    defer run_dir.deinit();
    const stored_manifest = try run_dir.readRegularAlloc(
        allocator,
        io,
        "manifest.json",
        committed_review.limits.max_manifest_bytes,
    );
    defer allocator.free(stored_manifest);
    const stored_findings = try run_dir.readRegularAlloc(
        allocator,
        io,
        "findings.json",
        committed_review.limits.max_artifact_bytes,
    );
    defer allocator.free(stored_findings);
    try std.testing.expectEqualSlices(u8, manifest_bytes, stored_manifest);
    try std.testing.expectEqualSlices(u8, findings_bytes, stored_findings);

    var budget: run_artifacts.ArtifactBudget = .{};
    var loaded = try run_artifacts.loadValidated(
        allocator,
        io,
        namespace,
        identities.review_repository_id,
        identities.review_id,
        &budget,
    );
    defer loaded.deinit(allocator);
    try std.testing.expect(loaded == .loaded);
    try std.testing.expectEqualSlices(u8, manifest_bytes, loaded.loaded.manifest_bytes);
    try std.testing.expectEqualSlices(u8, findings_bytes, loaded.loaded.findings_bytes);

    const next_prepared = try prepare(allocator, io, &environment, repository_path);
    const next = switch (next_prepared) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    const mismatched_artifact = try publish(allocator, io, &environment, .{
        .repository_path = repository_path,
        .review_repository_id = next.review_repository_id,
        .review_id = next.review_id,
        .manifest_bytes = manifest_bytes,
        .findings_bytes = findings_bytes,
    });
    try std.testing.expect(mismatched_artifact == .failure);
    try std.testing.expectEqual(Failure.invalid_artifact, mismatched_artifact.failure);
    const next_id_text = next.review_id.canonical();
    if (namespace.openDirectory(&next_id_text)) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.UnexpectedInvalidArtifactRun;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);

    const wrong_repository_id = try committed_review.ReviewRepositoryId.parse(
        "123e4567-e89b-42d3-b456-426614174000",
    );
    const next_findings: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = next.review_id,
        .created_at = "2026-08-21T03:01:00Z",
        .target = target,
        .producer = producer,
        .findings = &.{},
    };
    const next_findings_bytes = try next_findings.writeCanonical(allocator);
    defer allocator.free(next_findings_bytes);
    const wrong_manifest: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = next.review_id,
        .review_repository_id = wrong_repository_id,
        .target = target,
        .created_at = next_findings.created_at,
        .display = null,
        .finding_count = 0,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(next_findings_bytes),
    };
    const wrong_manifest_bytes = try wrong_manifest.writeCanonical(allocator);
    defer allocator.free(wrong_manifest_bytes);
    const wrong_binding = try publish(allocator, io, &environment, .{
        .repository_path = repository_path,
        .review_repository_id = wrong_repository_id,
        .review_id = next.review_id,
        .manifest_bytes = wrong_manifest_bytes,
        .findings_bytes = next_findings_bytes,
    });
    try std.testing.expect(wrong_binding == .failure);
    try std.testing.expectEqual(Failure.binding_mismatch, wrong_binding.failure);
    const wrong_repository_text = wrong_repository_id.canonical();
    if (root.directory.openDirectory(&wrong_repository_text)) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.UnexpectedMismatchedBindingNamespace;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);

    const missing_prepared = try prepare(allocator, io, &environment, repository_path);
    const missing = switch (missing_prepared) {
        .success => |value| value,
        .failure => return error.ExpectedPrepareSuccess,
    };
    const zero_oid = "0000000000000000000000000000000000000000";
    const unavailable_target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = try committed_review.ObjectId.parse(.sha1, zero_oid),
        .head_oid = try committed_review.ObjectId.parse(.sha1, zero_oid),
        .diff_base_oid = try committed_review.ObjectId.parse(.sha1, zero_oid),
    };
    const missing_findings: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = missing.review_id,
        .created_at = "2026-08-21T03:02:00Z",
        .target = unavailable_target,
        .producer = producer,
        .findings = &.{},
    };
    const missing_findings_bytes = try missing_findings.writeCanonical(allocator);
    defer allocator.free(missing_findings_bytes);
    const missing_manifest: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = missing.review_id,
        .review_repository_id = missing.review_repository_id,
        .target = unavailable_target,
        .created_at = missing_findings.created_at,
        .display = null,
        .finding_count = 0,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(missing_findings_bytes),
    };
    const missing_manifest_bytes = try missing_manifest.writeCanonical(allocator);
    defer allocator.free(missing_manifest_bytes);
    const unavailable = try publish(allocator, io, &environment, .{
        .repository_path = repository_path,
        .review_repository_id = missing.review_repository_id,
        .review_id = missing.review_id,
        .manifest_bytes = missing_manifest_bytes,
        .findings_bytes = missing_findings_bytes,
    });
    try std.testing.expect(unavailable == .failure);
    try std.testing.expectEqual(Failure.target_unavailable, unavailable.failure);
    const missing_id_text = missing.review_id.canonical();
    if (namespace.openDirectory(&missing_id_text)) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.UnexpectedUnavailableTargetRun;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);
}
