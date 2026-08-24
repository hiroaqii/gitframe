//! Bounded read-only history scan and selection-time exact revalidation.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const git_command = @import("../git/command.zig");
const git_review = @import("../git/committed_review.zig");
const repository_locator = @import("../git/repository_locator.zig");
const root_capability = @import("../repo/root_capability.zig");
const capability = @import("capability.zig");
const catalog_store = @import("catalog.zig");
const core = @import("core.zig");
const run = @import("run.zig");
const store_path = @import("path.zig");

pub const max_namespace_entries = catalog_store.max_namespace_entries;
pub const max_run_candidates = catalog_store.max_run_candidates;
pub const max_enumerated_name_bytes = catalog_store.max_enumerated_name_bytes;
pub const max_diagnostics = catalog_store.max_diagnostics;
pub const max_diagnostic_bytes = catalog_store.max_diagnostic_bytes;

pub const RepositoryContext = struct {
    capability: *const root_capability.RootCapability,
    environment: *const git_command.LocalGitEnvironment,

    fn git(self: RepositoryContext) git_command.DirectoryContext {
        return .{ .cwd = self.capability.dir(), .environment = self.environment };
    }
};

pub const StoreSnapshot = catalog_store.StoreSnapshot;

/// Display-safe lifecycle projection for one validated Run. Terminal values
/// preserve the exact human decision instead of collapsing it to `completed`.
pub const RunSummaryStatus = catalog_store.RunStatus;

pub const RunSummary = struct {
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
    status: RunSummaryStatus,
    created_at: [20]u8,
    created_at_unix: i64,
    producer_name: []u8,
    producer_model: ?[]u8,
    base_label: ?[]u8,
    head_label: ?[]u8,
    finding_count: u32,
    availability: git_review.TargetAvailability,
    artifact_snapshot: run.ArtifactSnapshot,

    pub fn deinit(self: *RunSummary, allocator: std.mem.Allocator) void {
        if (self.head_label) |value| allocator.free(value);
        if (self.base_label) |value| allocator.free(value);
        if (self.producer_model) |value| allocator.free(value);
        allocator.free(self.producer_name);
        self.* = undefined;
    }
};

pub const DiagnosticKind = catalog_store.DiagnosticKind;

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    text: []u8,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const History = struct {
    snapshot: StoreSnapshot,
    rows: []RunSummary,
    diagnostics: []Diagnostic,
    skipped_count: usize,
    orphan_count: usize,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const BoundEmpty = struct { snapshot: StoreSnapshot };

pub const ScanFailure = enum {
    repository_invalid,
    store_invalid,
    store_unavailable,
    unsupported_platform,
    unsupported_filesystem,
    registry_invalid,
    registry_unavailable,
    namespace_invalid,
    enumeration_failed,
    scan_limit_exceeded,
    git_failed,
};

pub const ScanResult = union(enum) {
    unbound,
    bound_empty: BoundEmpty,
    history: History,
    failure: ScanFailure,

    pub fn deinit(self: *ScanResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .history => |*value| value.deinit(allocator),
            .unbound, .bound_empty, .failure => {},
        }
        self.* = .unbound;
    }
};

pub fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_root: []const u8,
    repository: RepositoryContext,
) std.mem.Allocator.Error!ScanResult {
    const located = try repository_locator.locate(allocator, io, repository.git());
    const locator = switch (located) {
        .locator => |value| value,
        .failure => return .{ .failure = .repository_invalid },
    };
    var context = core.Context.initConfigured(allocator, store_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidStoreRoot => return .{ .failure = .store_invalid },
    };
    defer context.deinit(allocator);
    var scanned = try catalog_store.scan(allocator, io, &context, locator);
    defer scanned.deinit(allocator);
    const catalog_value = switch (scanned) {
        .unbound => return .unbound,
        .bound_empty => |value| return .{ .bound_empty = .{ .snapshot = value.snapshot } },
        .failure => |failure| return .{ .failure = mapCatalogScanFailure(failure) },
        .catalog => |*value| value,
    };

    var rows: std.ArrayList(RunSummary) = .empty;
    defer deinitRows(allocator, &rows);
    for (catalog_value.rows) |*row| {
        const summary = try summaryFromCatalogRow(allocator, row);
        rows.append(allocator, summary) catch |err| {
            var owned = summary;
            owned.deinit(allocator);
            return err;
        };
    }
    if (rows.items.len != 0) {
        const targets = try allocator.alloc(committed_review.CommittedReviewTarget, rows.items.len);
        defer allocator.free(targets);
        for (rows.items, 0..) |row, index| targets[index] = row.target;
        var availability = try git_review.checkTargetsAvailability(allocator, io, repository.git(), targets);
        defer availability.deinit(allocator);
        const values = switch (availability) {
            .available => |items| items,
            .failure => return .{ .failure = .git_failed },
        };
        for (rows.items, values) |*row, value| row.availability = value;
    }
    std.mem.sort(RunSummary, rows.items, {}, summaryLessThan);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(allocator, &diagnostics);
    for (catalog_value.diagnostics) |diagnostic| {
        try appendDiagnostic(allocator, &diagnostics, diagnostic.kind, diagnostic.text);
    }
    const owned_rows = try rows.toOwnedSlice(allocator);
    errdefer {
        for (owned_rows) |*row| row.deinit(allocator);
        allocator.free(owned_rows);
    }
    const owned_diagnostics = try diagnostics.toOwnedSlice(allocator);
    errdefer {
        for (owned_diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(owned_diagnostics);
    }
    return .{ .history = .{
        .snapshot = catalog_value.snapshot,
        .rows = owned_rows,
        .diagnostics = owned_diagnostics,
        .skipped_count = catalog_value.skipped_count,
        .orphan_count = catalog_value.orphan_count,
    } };
}

fn mapCatalogScanFailure(failure: catalog_store.ScanFailure) ScanFailure {
    return switch (failure) {
        .store_invalid => .store_invalid,
        .store_unavailable => .store_unavailable,
        .unsupported_platform => .unsupported_platform,
        .unsupported_filesystem => .unsupported_filesystem,
        .registry_invalid => .registry_invalid,
        .registry_unavailable => .registry_unavailable,
        .namespace_invalid => .namespace_invalid,
        .enumeration_failed => .enumeration_failed,
        .scan_limit_exceeded => .scan_limit_exceeded,
    };
}

fn summaryFromCatalogRow(
    allocator: std.mem.Allocator,
    row: *const catalog_store.CatalogRow,
) std.mem.Allocator.Error!RunSummary {
    var summary: RunSummary = .{
        .review_id = row.review_id,
        .target = row.target,
        .status = row.status,
        .created_at = row.created_at,
        .created_at_unix = row.created_at_unix,
        .producer_name = try allocator.dupe(u8, row.producer_name),
        .producer_model = null,
        .base_label = null,
        .head_label = null,
        .finding_count = row.finding_count,
        .availability = .available,
        .artifact_snapshot = row.artifact_snapshot,
    };
    errdefer summary.deinit(allocator);
    if (row.producer_model) |value| summary.producer_model = try allocator.dupe(u8, value);
    if (row.base_label) |value| summary.base_label = try allocator.dupe(u8, value);
    if (row.head_label) |value| summary.head_label = try allocator.dupe(u8, value);
    return summary;
}

fn summaryLessThan(_: void, left: RunSummary, right: RunSummary) bool {
    if (left.created_at_unix != right.created_at_unix) return left.created_at_unix > right.created_at_unix;
    const left_text = left.review_id.canonical();
    const right_text = right.review_id.canonical();
    return std.mem.lessThan(u8, &left_text, &right_text);
}

fn appendDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    kind: DiagnosticKind,
    raw_name: []const u8,
) std.mem.Allocator.Error!void {
    if (diagnostics.items.len == max_diagnostics) return;
    const sanitized = try sanitizeDiagnostic(allocator, raw_name);
    diagnostics.append(allocator, .{ .kind = kind, .text = sanitized }) catch |err| {
        allocator.free(sanitized);
        return err;
    };
}

fn sanitizeDiagnostic(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    const length = @min(raw.len, max_diagnostic_bytes);
    const value = try allocator.alloc(u8, length);
    for (raw[0..length], 0..) |byte, index| {
        value[index] = if (byte >= 0x20 and byte < 0x7f) byte else '?';
    }
    return value;
}

fn deinitRows(allocator: std.mem.Allocator, rows: *std.ArrayList(RunSummary)) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

fn deinitDiagnostics(allocator: std.mem.Allocator, values: *std.ArrayList(Diagnostic)) void {
    for (values.items) |*value| value.deinit(allocator);
    values.deinit(allocator);
}

pub const SelectionFailure = enum {
    repository_unavailable,
    root_drift,
    binding_drift,
    run_invalid,
    artifact_drift,
    target_unavailable,
    git_failed,
    projection_failed,
};

pub const SelectedRunRead = struct {
    store_root_path: []u8,
    store: capability.StoreRootCapability,
    repository: root_capability.RootCapability,
    environment: git_command.LocalGitEnvironment,
    snapshot: StoreSnapshot,
    artifacts: run.LoadedRunArtifacts,
    projection: git_review.CommittedDiffProjection,

    pub fn deinit(self: *SelectedRunRead, allocator: std.mem.Allocator) void {
        self.projection.deinit(allocator);
        self.artifacts.deinit(allocator);
        self.environment.deinit();
        self.repository.deinit();
        self.store.deinit();
        allocator.free(self.store_root_path);
        self.* = undefined;
    }
};

pub const SelectionResult = union(enum) {
    selected: SelectedRunRead,
    failure: SelectionFailure,

    pub fn deinit(self: *SelectionResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .selected => |*value| value.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .run_invalid };
    }
};

pub fn loadSelection(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_root: []const u8,
    repository: RepositoryContext,
    expected: StoreSnapshot,
    review_id: committed_review.ReviewId,
    expected_artifacts: run.ArtifactSnapshot,
) std.mem.Allocator.Error!SelectionResult {
    const owned_path = try allocator.dupe(u8, store_root);
    var transferred = false;
    defer if (!transferred) allocator.free(owned_path);
    var owned_repository = repository.capability.duplicate() catch
        return .{ .failure = .repository_unavailable };
    defer if (!transferred) owned_repository.deinit();
    var owned_environment = git_command.LocalGitEnvironment.initFromParent(
        allocator,
        repository.environment.borrow(),
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .repository_unavailable };
    };
    defer if (!transferred) owned_environment.deinit();
    const owned_context: RepositoryContext = .{
        .capability = &owned_repository,
        .environment = &owned_environment,
    };

    const located = try repository_locator.locate(allocator, io, owned_context.git());
    const locator = switch (located) {
        .locator => |value| value,
        .failure => return .{ .failure = .repository_unavailable },
    };
    if (!locator.eql(expected.repository_locator)) return .{ .failure = .binding_drift };

    var store_context = core.Context.initConfigured(allocator, owned_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidStoreRoot => return .{ .failure = .root_drift },
    };
    defer store_context.deinit(allocator);
    var exact_result = try catalog_store.readExact(
        allocator,
        io,
        &store_context,
        locator,
        review_id,
        expected,
        expected_artifacts,
    );
    defer exact_result.deinit(allocator);
    const exact = switch (exact_result) {
        .exact => |*value| value,
        .absent => return .{ .failure = .run_invalid },
        .failure => |failure| return .{ .failure = mapExactReadFailure(failure) },
    };

    const availability = try git_review.checkTargetAvailability(
        allocator,
        io,
        owned_context.git(),
        exact.artifacts.manifest.value.target,
    );
    switch (availability) {
        .availability => |value| if (value == .missing) return .{ .failure = .target_unavailable },
        .failure => return .{ .failure = .git_failed },
    }
    var projection_result = try git_review.materializeCommittedProjection(
        allocator,
        io,
        owned_context.git(),
        exact.artifacts.manifest.value.target,
    );
    defer projection_result.deinit(allocator);
    const projection = switch (projection_result) {
        .projection => |value| value,
        .failure => return .{ .failure = .projection_failed },
    };

    const store = exact.root.root;
    const artifacts = exact.artifacts;
    exact_result = .absent;
    projection_result = .{ .failure = .projection_git_command_failed };
    transferred = true;
    return .{ .selected = .{
        .store_root_path = owned_path,
        .store = store,
        .repository = owned_repository,
        .environment = owned_environment,
        .snapshot = expected,
        .artifacts = artifacts,
        .projection = projection,
    } };
}

fn mapExactReadFailure(failure: catalog_store.ReadFailure) SelectionFailure {
    return switch (failure) {
        .root_changed => .root_drift,
        .binding_changed => .binding_drift,
        .artifact_changed => .artifact_drift,
        .registry_invalid, .registry_unavailable => .binding_drift,
        .artifact_invalid, .namespace_invalid, .concurrent_conflict => .run_invalid,
        .store_unavailable, .unsupported_platform, .unsupported_filesystem, .store_invalid => .root_drift,
    };
}

test "review history backend summary sorting ignores filesystem and completion time" {
    const older = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const first_tie = try committed_review.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000");
    var rows = [_]RunSummary{
        undefined,
        undefined,
        undefined,
    };
    rows[0].review_id = older;
    rows[0].created_at_unix = 1;
    rows[1].review_id = older;
    rows[1].created_at_unix = 2;
    rows[2].review_id = first_tie;
    rows[2].created_at_unix = 2;
    std.mem.sort(RunSummary, &rows, {}, summaryLessThan);
    try std.testing.expect(rows[0].review_id.eql(first_tie));
    try std.testing.expect(rows[1].review_id.eql(older));
    try std.testing.expectEqual(@as(i64, 1), rows[2].created_at_unix);
}

test "review history backend diagnostics are bounded and terminal-control safe" {
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer deinitDiagnostics(std.testing.allocator, &diagnostics);
    for (0..max_diagnostics + 4) |index| {
        const raw = if (index == 0) "bad\n\x1bname" else "bad";
        try appendDiagnostic(std.testing.allocator, &diagnostics, .invalid_run, raw);
    }
    try std.testing.expectEqual(max_diagnostics, diagnostics.items.len);
    try std.testing.expectEqualStrings("bad??name", diagnostics.items[0].text);
}

const TestRunMode = enum {
    new,
    draft,
    completed,
    completed_needs_changes,
    completed_canceled,
    completed_invalid_draft,
    completed_unsafe_draft,
    invalid_result,
    unknown_entry,
};

fn runTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    std.testing.allocator.free(result.stdout);
    return error.GitCommandFailed;
}

fn singleOutputLine(bytes: []const u8) ![]const u8 {
    if (bytes.len < 2 or bytes[bytes.len - 1] != '\n' or
        std.mem.indexOfScalar(u8, bytes[0 .. bytes.len - 1], '\n') != null)
    {
        return error.InvalidGitOutput;
    }
    return bytes[0 .. bytes.len - 1];
}

fn writePrivate(io: std.Io, directory: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    try directory.writeFile(io, .{
        .sub_path = name,
        .data = bytes,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
}

fn seedTestRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: std.Io.Dir,
    repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
    created_at: []const u8,
    mode: TestRunMode,
) !void {
    const review_text = review_id.canonical();
    try namespace.createDir(io, &review_text, .fromMode(0o700));
    var directory = try namespace.openDir(io, &review_text, .{});
    defer directory.close(io);

    const producer: committed_review.Producer = .{ .name = "codex", .model = "gpt-test" };
    const finding_set: committed_review.FindingSet = .{
        .schema_version = 1,
        .review_id = review_id,
        .created_at = created_at,
        .timing = .{ .duration_ms = 42 },
        .target = target,
        .producer = producer,
        .findings = &.{},
    };
    const findings_bytes = try finding_set.writeCanonical(allocator);
    defer allocator.free(findings_bytes);
    const manifest: committed_review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = review_id,
        .review_repository_id = repository_id,
        .target = target,
        .created_at = created_at,
        .display = .{ .base_label = "main~1", .head_label = "main" },
        .finding_count = 0,
        .producer = producer,
        .findings_digest = committed_review.Sha256Digest.hash(findings_bytes),
    };
    const manifest_bytes = try manifest.writeCanonical(allocator);
    defer allocator.free(manifest_bytes);
    try writePrivate(io, directory, "manifest.json", manifest_bytes);
    try writePrivate(io, directory, "findings.json", findings_bytes);

    switch (mode) {
        .new => {},
        .draft, .invalid_result => {
            const draft: committed_review.ReviewDraftState = .{
                .schema_version = 1,
                .review_id = review_id,
                .target = target,
                .findings_digest = manifest.findings_digest,
                .revision = 1,
                .summary = null,
                .finding_dispositions = &.{},
                .anchored_notes = &.{},
            };
            const draft_bytes = try draft.writeCanonical(allocator);
            defer allocator.free(draft_bytes);
            try writePrivate(io, directory, "review_state.json", draft_bytes);
            if (mode == .invalid_result) try writePrivate(io, directory, "result.json", "{}\n");
        },
        .completed,
        .completed_needs_changes,
        .completed_canceled,
        .completed_invalid_draft,
        .completed_unsafe_draft,
        => {
            const result: committed_review.RevisionReviewResult = .{
                .schema_version = 1,
                .review_id = review_id,
                .target = target,
                .findings_digest = manifest.findings_digest,
                .result = switch (mode) {
                    .completed_needs_changes => .needs_changes,
                    .completed_canceled => .canceled,
                    else => .approved,
                },
                .completed_at = "2026-08-20T09:00:00Z",
                .summary = if (mode == .completed_needs_changes) "Changes required." else null,
                .finding_dispositions = &.{},
                .anchored_notes = &.{},
            };
            const result_bytes = try result.writeCanonical(allocator);
            defer allocator.free(result_bytes);
            try writePrivate(io, directory, "result.json", result_bytes);
            if (mode == .completed_invalid_draft) {
                try writePrivate(io, directory, "review_state.json", "");
            } else if (mode == .completed_unsafe_draft) {
                try directory.symLink(io, "manifest.json", "review_state.json", .{});
            }
        },
        .unknown_entry => try writePrivate(io, directory, "unexpected.tmp", "x"),
    }
}

fn testSummary(history: *const History, review_id: committed_review.ReviewId) !*const RunSummary {
    for (history.rows) |*summary| {
        if (summary.review_id.eql(review_id)) return summary;
    }
    return error.ExpectedReviewSummary;
}

test "review history backend AI Reviews picker scan and selection preserve every status result precedence and exact Git target" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    var output = try runTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
    allocator.free(output);
    try repo.writeFile(io, .{ .sub_path = "file.txt", .data = "base\n" });
    output = try runTestGit(io, repo, &.{ "git", "add", "file.txt" });
    allocator.free(output);
    output = try runTestGit(io, repo, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    allocator.free(output);
    const base_output = try runTestGit(io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_output);
    const base_text = try singleOutputLine(base_output);
    try repo.writeFile(io, .{ .sub_path = "file.txt", .data = "changed\n" });
    output = try runTestGit(io, repo, &.{ "git", "add", "file.txt" });
    allocator.free(output);
    output = try runTestGit(io, repo, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });
    allocator.free(output);
    const head_output = try runTestGit(io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_output);
    const head_text = try singleOutputLine(head_output);
    const target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = try committed_review.ObjectId.parse(.sha1, base_text),
        .head_oid = try committed_review.ObjectId.parse(.sha1, head_text),
        .diff_base_oid = try committed_review.ObjectId.parse(.sha1, base_text),
    };

    const repo_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo_path);
    var repo_capability = try root_capability.RootCapability.openCanonical(repo_path);
    defer repo_capability.deinit();
    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    const repository: RepositoryContext = .{ .capability = &repo_capability, .environment = &environment };
    const locator_result = try repository_locator.locate(allocator, io, repository.git());
    const locator = switch (locator_result) {
        .locator => |value| value,
        .failure => return error.ExpectedRepositoryLocator,
    };

    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    var store = try tmp.dir.openDir(io, "store", .{});
    defer store.close(io);
    const repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const repository_text = repository_id.canonical();
    const registry_bytes = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"bindings\":[{{\"review_repository_id\":\"{s}\",\"device\":\"{d}\",\"inode\":\"{d}\",\"canonical_path\":{{\"encoding\":\"utf8\",\"value\":\"{s}\"}},\"last_seen_path\":{{\"encoding\":\"utf8\",\"value\":\"{s}\"}}}}]}}\n", .{ &repository_text, locator.device, locator.inode, repo_path, repo_path });
    defer allocator.free(registry_bytes);
    try writePrivate(io, store, "registry.json", registry_bytes);
    try store.createDir(io, &repository_text, .fromMode(0o700));
    var namespace = try store.openDir(io, &repository_text, .{});
    defer namespace.close(io);

    const valid_id = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const invalid_result_id = try committed_review.ReviewId.parse("323e4567-e89b-42d3-a456-426614174000");
    const unknown_entry_id = try committed_review.ReviewId.parse("423e4567-e89b-42d3-a456-426614174000");
    const unsafe_draft_id = try committed_review.ReviewId.parse("723e4567-e89b-42d3-a456-426614174000");
    const new_id = try committed_review.ReviewId.parse("a23e4567-e89b-42d3-a456-426614174000");
    const draft_id = try committed_review.ReviewId.parse("b23e4567-e89b-42d3-a456-426614174000");
    const completed_id = try committed_review.ReviewId.parse("c23e4567-e89b-42d3-a456-426614174000");
    const needs_changes_id = try committed_review.ReviewId.parse("923e4567-e89b-42d3-a456-426614174000");
    const canceled_id = try committed_review.ReviewId.parse("f23e4567-e89b-42d3-a456-426614174000");
    try seedTestRun(allocator, io, namespace, repository_id, new_id, target, "2026-08-20T11:00:00Z", .new);
    try seedTestRun(allocator, io, namespace, repository_id, draft_id, target, "2026-08-20T10:00:00Z", .draft);
    try seedTestRun(allocator, io, namespace, repository_id, completed_id, target, "2026-08-20T09:00:00Z", .completed);
    try seedTestRun(allocator, io, namespace, repository_id, needs_changes_id, target, "2026-08-20T08:30:00Z", .completed_needs_changes);
    try seedTestRun(allocator, io, namespace, repository_id, canceled_id, target, "2026-08-20T08:15:00Z", .completed_canceled);
    try seedTestRun(allocator, io, namespace, repository_id, valid_id, target, "2026-08-20T08:00:00Z", .completed_invalid_draft);
    try seedTestRun(allocator, io, namespace, repository_id, invalid_result_id, target, "2026-08-20T07:00:00Z", .invalid_result);
    try seedTestRun(allocator, io, namespace, repository_id, unknown_entry_id, target, "2026-08-20T06:00:00Z", .unknown_entry);
    try seedTestRun(allocator, io, namespace, repository_id, unsafe_draft_id, target, "2026-08-20T04:00:00Z", .completed_unsafe_draft);

    const token = [_]u8{0xab} ** 16;
    const temp: store_path.NamespaceTempName = .{ .kind = .publish, .review_id = valid_id, .token = token };
    const temp_name = temp.format();
    try namespace.createDir(io, temp_name.slice(), .fromMode(0o700));
    const draft_temp: store_path.NamespaceTempName = .{ .kind = .draft, .review_id = valid_id, .token = token };
    const draft_temp_name = draft_temp.format();
    try writePrivate(io, namespace, draft_temp_name.slice(), "draft orphan");
    const result_temp: store_path.NamespaceTempName = .{ .kind = .result, .review_id = valid_id, .token = token };
    const result_temp_name = result_temp.format();
    try writePrivate(io, namespace, result_temp_name.slice(), "result orphan");
    try namespace.symLink(io, &repository_text, ".tmp-publish-523e4567-e89b-42d3-a456-426614174000-cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", .{ .is_directory = true });
    try namespace.createDir(io, ".tmp-draft-523e4567-e89b-42d3-a456-426614174000-cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", .fromMode(0o700));
    try namespace.symLink(io, &repository_text, ".tmp-result-523e4567-e89b-42d3-a456-426614174000-cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", .{});
    try writePrivate(io, namespace, ".tmp-malformed", "x");

    const store_path_text = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_path_text);
    var scanned = try scan(allocator, io, store_path_text, repository);
    defer scanned.deinit(allocator);
    const history = switch (scanned) {
        .history => |*value| value,
        else => return error.ExpectedReviewHistory,
    };
    try std.testing.expectEqual(@as(usize, 7), history.rows.len);
    try std.testing.expectEqual(RunSummaryStatus.new, (try testSummary(history, new_id)).status);
    try std.testing.expectEqual(RunSummaryStatus.draft, (try testSummary(history, draft_id)).status);
    try std.testing.expectEqual(RunSummaryStatus.approved, (try testSummary(history, completed_id)).status);
    try std.testing.expectEqual(RunSummaryStatus.needs_changes, (try testSummary(history, needs_changes_id)).status);
    try std.testing.expectEqual(RunSummaryStatus.canceled, (try testSummary(history, canceled_id)).status);
    const valid_row = try testSummary(history, valid_id);
    try std.testing.expectEqual(RunSummaryStatus.approved, valid_row.status);
    try std.testing.expectEqual(git_review.TargetAvailability.available, valid_row.availability);
    try std.testing.expectEqual(@as(u32, 0), valid_row.finding_count);
    try std.testing.expectEqual(run.DraftSnapshotState.invalid, valid_row.artifact_snapshot.draft_state);
    try std.testing.expectEqual(@as(usize, 3), history.orphan_count);
    try std.testing.expect(history.skipped_count >= 6);
    try std.testing.expectEqual(RunSummaryStatus.approved, (try testSummary(history, unsafe_draft_id)).status);

    var selected = try loadSelection(
        allocator,
        io,
        store_path_text,
        repository,
        history.snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer selected.deinit(allocator);
    const selected_value = switch (selected) {
        .selected => |*owned| owned,
        .failure => return error.ExpectedSelectedReviewRun,
    };
    try std.testing.expect(selected_value.artifacts.state == .completed);
    try std.testing.expect(selected_value.artifacts.retained_draft_diagnostic == .invalid);
    try std.testing.expect(std.mem.indexOf(u8, selected_value.projection.patch_bytes, "+changed") != null);

    try tmp.dir.createDir(io, "not-repository", .default_dir);
    var not_repository_directory = try tmp.dir.openDir(io, "not-repository", .{});
    defer not_repository_directory.close(io);
    try not_repository_directory.writeFile(io, .{
        .sub_path = ".git",
        .data = "gitdir: missing-git-directory\n",
    });
    const not_repository_path = try tmp.dir.realPathFileAlloc(io, "not-repository", allocator);
    defer allocator.free(not_repository_path);
    var not_repository_capability = try root_capability.RootCapability.openCanonical(not_repository_path);
    defer not_repository_capability.deinit();
    const not_repository: RepositoryContext = .{
        .capability = &not_repository_capability,
        .environment = &environment,
    };
    var repository_unavailable = try loadSelection(
        allocator,
        io,
        store_path_text,
        not_repository,
        history.snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer repository_unavailable.deinit(allocator);
    try std.testing.expect(repository_unavailable == .failure);
    try std.testing.expectEqual(SelectionFailure.repository_unavailable, repository_unavailable.failure);

    {
        var registry_file = try store.openFile(io, "registry.json", .{ .mode = .read_write });
        defer registry_file.close(io);
        try registry_file.setPermissions(io, .fromMode(0o640));
    }
    var unsafe_registry = try scan(allocator, io, store_path_text, repository);
    defer unsafe_registry.deinit(allocator);
    try std.testing.expect(unsafe_registry == .failure);
    try std.testing.expectEqual(ScanFailure.registry_invalid, unsafe_registry.failure);
    {
        var registry_file = try store.openFile(io, "registry.json", .{ .mode = .read_write });
        defer registry_file.close(io);
        try registry_file.setPermissions(io, .fromMode(0o600));
    }

    try store.deleteFile(io, "registry.json");
    try writePrivate(io, store, "registry-target.json", registry_bytes);
    try store.symLink(io, "registry-target.json", "registry.json", .{});
    var symlink_registry = try scan(allocator, io, store_path_text, repository);
    defer symlink_registry.deinit(allocator);
    try std.testing.expect(symlink_registry == .failure);
    try std.testing.expectEqual(ScanFailure.registry_invalid, symlink_registry.failure);
    try store.deleteFile(io, "registry.json");
    try store.deleteFile(io, "registry-target.json");
    try writePrivate(io, store, "registry.json", registry_bytes);

    var drifted_snapshot = history.snapshot;
    drifted_snapshot.root_inode +%= 1;
    var drifted = try loadSelection(
        allocator,
        io,
        store_path_text,
        repository,
        drifted_snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer drifted.deinit(allocator);
    try std.testing.expect(drifted == .failure);
    try std.testing.expectEqual(SelectionFailure.root_drift, drifted.failure);

    var missing_target = target;
    missing_target.head_oid = try committed_review.ObjectId.parse(.sha1, "ffffffffffffffffffffffffffffffffffffffff");
    const missing = try git_review.checkTargetAvailability(allocator, io, repository.git(), missing_target);
    try std.testing.expect(missing == .availability);
    try std.testing.expectEqual(git_review.TargetAvailability.missing, missing.availability);
    const missing_target_id = try committed_review.ReviewId.parse("823e4567-e89b-42d3-a456-426614174000");
    try seedTestRun(allocator, io, namespace, repository_id, missing_target_id, missing_target, "2026-08-20T03:00:00Z", .completed_invalid_draft);

    try repo.writeFile(io, .{
        .sub_path = "broken.commit",
        .data = "tree ffffffffffffffffffffffffffffffffffffffff\n" ++
            "author Test <test@example.invalid> 0 +0000\n" ++
            "committer Test <test@example.invalid> 0 +0000\n\n" ++
            "broken tree\n",
    });
    const broken_output = try runTestGit(io, repo, &.{ "git", "hash-object", "-t", "commit", "-w", "--literally", "broken.commit" });
    defer allocator.free(broken_output);
    const broken_text = try singleOutputLine(broken_output);
    const projection_failure_target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = target.base_oid,
        .head_oid = try committed_review.ObjectId.parse(.sha1, broken_text),
        .diff_base_oid = target.diff_base_oid,
    };
    const projection_failure_id = try committed_review.ReviewId.parse("d23e4567-e89b-42d3-a456-426614174000");
    try seedTestRun(
        allocator,
        io,
        namespace,
        repository_id,
        projection_failure_id,
        projection_failure_target,
        "2026-08-20T02:00:00Z",
        .completed,
    );
    var rescanned = try scan(allocator, io, store_path_text, repository);
    defer rescanned.deinit(allocator);
    const history_with_missing = switch (rescanned) {
        .history => |*value| value,
        else => return error.ExpectedReviewHistory,
    };
    var missing_snapshot: ?run.ArtifactSnapshot = null;
    var projection_failure_snapshot: ?run.ArtifactSnapshot = null;
    for (history_with_missing.rows) |row| {
        if (row.review_id.eql(missing_target_id)) {
            try std.testing.expectEqual(git_review.TargetAvailability.missing, row.availability);
            missing_snapshot = row.artifact_snapshot;
        } else if (row.review_id.eql(projection_failure_id)) {
            try std.testing.expectEqual(git_review.TargetAvailability.available, row.availability);
            projection_failure_snapshot = row.artifact_snapshot;
        }
    }
    try std.testing.expect(missing_snapshot != null);
    try std.testing.expect(projection_failure_snapshot != null);
    var unavailable_selection = try loadSelection(
        allocator,
        io,
        store_path_text,
        repository,
        history_with_missing.snapshot,
        missing_target_id,
        missing_snapshot.?,
    );
    defer unavailable_selection.deinit(allocator);
    try std.testing.expect(unavailable_selection == .failure);
    try std.testing.expectEqual(SelectionFailure.target_unavailable, unavailable_selection.failure);

    var projection_failed = try loadSelection(
        allocator,
        io,
        store_path_text,
        repository,
        history_with_missing.snapshot,
        projection_failure_id,
        projection_failure_snapshot.?,
    );
    defer projection_failed.deinit(allocator);
    try std.testing.expect(projection_failed == .failure);
    try std.testing.expectEqual(SelectionFailure.projection_failed, projection_failed.failure);

    var binding_snapshot = history.snapshot;
    binding_snapshot.review_repository_id = try committed_review.ReviewRepositoryId.parse("923e4567-e89b-42d3-a456-426614174000");
    var binding_drift = try loadSelection(
        allocator,
        io,
        store_path_text,
        repository,
        binding_snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer binding_drift.deinit(allocator);
    try std.testing.expect(binding_drift == .failure);
    try std.testing.expectEqual(SelectionFailure.binding_drift, binding_drift.failure);

    const missing_store = try std.fs.path.join(allocator, &.{ store_path_text, "absent" });
    defer allocator.free(missing_store);
    var absent = try scan(allocator, io, missing_store, repository);
    defer absent.deinit(allocator);
    try std.testing.expect(absent == .unbound);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openDirAbsolute(io, missing_store, .{}));

    const valid_text = valid_id.canonical();
    var valid_directory = try namespace.openDir(io, &valid_text, .{});
    defer valid_directory.close(io);
    const changed_result: committed_review.RevisionReviewResult = .{
        .schema_version = 1,
        .review_id = valid_id,
        .target = target,
        .findings_digest = selected_value.artifacts.manifest.value.findings_digest,
        .result = .approved,
        .completed_at = "2026-08-20T10:00:00Z",
        .summary = null,
        .finding_dispositions = &.{},
        .anchored_notes = &.{},
    };
    const changed_result_bytes = try changed_result.writeCanonical(allocator);
    defer allocator.free(changed_result_bytes);
    try writePrivate(io, valid_directory, "result.json", changed_result_bytes);
    var exact_drift = try loadSelection(
        allocator,
        io,
        store_path_text,
        repository,
        history.snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer exact_drift.deinit(allocator);
    try std.testing.expect(exact_drift == .failure);
    try std.testing.expectEqual(SelectionFailure.artifact_drift, exact_drift.failure);

    try writePrivate(io, valid_directory, "manifest.json", "{}\n");
    var invalid_artifact = try loadSelection(
        allocator,
        io,
        store_path_text,
        repository,
        history.snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer invalid_artifact.deinit(allocator);
    try std.testing.expect(invalid_artifact == .failure);
    try std.testing.expectEqual(SelectionFailure.run_invalid, invalid_artifact.failure);

    const sha256_oid = try committed_review.ObjectId.parse(.sha256, "0000000000000000000000000000000000000000000000000000000000000000");
    const mismatched_target: committed_review.CommittedReviewTarget = .{
        .object_format = .sha256,
        .source_kind = .branch_range,
        .base_oid = sha256_oid,
        .head_oid = sha256_oid,
        .diff_base_oid = sha256_oid,
    };
    const mismatched_id = try committed_review.ReviewId.parse("623e4567-e89b-42d3-a456-426614174000");
    try seedTestRun(allocator, io, namespace, repository_id, mismatched_id, mismatched_target, "2026-08-20T05:00:00Z", .completed_invalid_draft);
    var mismatch_store = try capability.StoreRootCapability.openCanonical(store_path_text);
    defer mismatch_store.deinit();
    var mismatch_namespace = try mismatch_store.directory.openDirectory(&repository_text);
    defer mismatch_namespace.deinit();
    var mismatch_budget: run.ArtifactBudget = .{};
    var mismatch_loaded = try run.loadValidated(
        allocator,
        io,
        mismatch_namespace,
        repository_id,
        mismatched_id,
        &mismatch_budget,
    );
    defer mismatch_loaded.deinit(allocator);
    const mismatch_snapshot = switch (mismatch_loaded) {
        .loaded => |*loaded| run.ArtifactSnapshot.fromLoaded(loaded),
        .invalid => return error.ExpectedMismatchedObjectFormatRun,
    };
    var git_failed = try loadSelection(
        allocator,
        io,
        store_path_text,
        repository,
        history.snapshot,
        mismatched_id,
        mismatch_snapshot,
    );
    defer git_failed.deinit(allocator);
    try std.testing.expect(git_failed == .failure);
    try std.testing.expectEqual(SelectionFailure.git_failed, git_failed.failure);
    var failed_scan = try scan(allocator, io, store_path_text, repository);
    defer failed_scan.deinit(allocator);
    try std.testing.expect(failed_scan == .failure);
    try std.testing.expectEqual(ScanFailure.git_failed, failed_scan.failure);

    for (0..max_namespace_entries + 1) |index| {
        const name = try std.fmt.allocPrint(allocator, ".unknown-{d}", .{index});
        writePrivate(io, namespace, name, "x") catch |err| {
            allocator.free(name);
            return err;
        };
        allocator.free(name);
    }
    var over_limit = try scan(allocator, io, store_path_text, repository);
    defer over_limit.deinit(allocator);
    try std.testing.expect(over_limit == .failure);
    try std.testing.expectEqual(ScanFailure.scan_limit_exceeded, over_limit.failure);

    try tmp.dir.rename("store", tmp.dir, "store-original", io);
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    var root_replaced = try loadSelection(
        allocator,
        io,
        store_path_text,
        repository,
        history.snapshot,
        valid_id,
        valid_row.artifact_snapshot,
    );
    defer root_replaced.deinit(allocator);
    try std.testing.expect(root_replaced == .failure);
    try std.testing.expectEqual(SelectionFailure.root_drift, root_replaced.failure);
}
