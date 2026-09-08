//! Concrete provider-neutral two-entry ReviewPipeline for hosted AI review.

const std = @import("std");
const committed = @import("../committed_review.zig");
const git_command = @import("../git/command.zig");
const git_review = @import("../git/committed_review.zig");
const root_capability = @import("../repo/root_capability.zig");
const process_runner = @import("../process/runner.zig");
const codex = @import("adapters/codex/adapter.zig");
const input_command = @import("input_command.zig");
const producer = @import("producer.zig");
const protocol = @import("protocol.zig");
const store_service = @import("store_service.zig");

pub const ProviderRequest = union(enum) {
    codex: codex.Request,

    pub fn deinit(self: *ProviderRequest) void {
        switch (self.*) {
            .codex => |*request| request.deinit(),
        }
        self.* = undefined;
    }
};

pub const FailureCode = enum {
    timed_out,
    repository_unavailable,
    target_unavailable,
    projection_failed,
    input_failed,
    input_too_large,
    provider_unavailable,
    provider_incompatible,
    provider_failed,
    invalid_provider_result,
    invalid_candidates,
    store_prepare_failed,
    artifact_failed,
    publish_failed,
    exact_reconciliation_failed,
    internal_error,
};

pub const Published = struct {
    review_id: committed.ReviewId,
    finding_count: u32,
};

pub const TerminalOutcome = union(enum) {
    published: Published,
    no_changes,
    failed: FailureCode,
    canceled,
    outcome_unknown: committed.ReviewId,
};

pub const CleanupWarning = enum {
    private_root_residue,
};

pub const Terminal = struct {
    outcome: TerminalOutcome,
    cleanup_warning: ?CleanupWarning = null,
};

const PublicationState = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    root: root_capability.RootCapability,
    environment: git_command.LocalGitEnvironment,
    store: store_service.ConfiguredStore,
    repository_path: []const u8,
    target: committed.CommittedReviewTarget,
    display: ?committed.DisplayMetadata,

    fn deinit(self: *PublicationState) void {
        self.store.deinit(self.allocator);
        self.environment.deinit();
        self.root.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    publication: PublicationState,
    owns_publication: bool = true,
    provider: ProviderRequest,
    owns_provider: bool = true,
    review_context: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        root: root_capability.RootCapability,
        parent_environment: ?*const std.process.Environ.Map,
        store: *const store_service.ConfiguredStore,
        repository_path: []const u8,
        target: committed.CommittedReviewTarget,
        display: ?committed.DisplayMetadata,
        provider: ProviderRequest,
        review_context: []const u8,
    ) !Request {
        var owned_provider = provider;
        errdefer owned_provider.deinit();
        var duplicate = try root.duplicate();
        errdefer duplicate.deinit();
        var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, parent_environment);
        errdefer environment.deinit();
        var configured_store = try store.clone(allocator);
        errdefer configured_store.deinit(allocator);
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        const owned_path = try arena.dupe(u8, repository_path);
        const owned_display: ?committed.DisplayMetadata = if (display) |value| .{
            .base_label = if (value.base_label) |label| try arena.dupe(u8, label) else null,
            .head_label = if (value.head_label) |label| try arena.dupe(u8, label) else null,
        } else null;
        const context = try allocator.dupe(u8, review_context);
        errdefer {
            std.crypto.secureZero(u8, context);
            allocator.free(context);
        }
        return .{
            .allocator = allocator,
            .publication = .{
                .allocator = allocator,
                .arena = arena_state,
                .root = duplicate,
                .environment = environment,
                .store = configured_store,
                .repository_path = owned_path,
                .target = target,
                .display = owned_display,
            },
            .provider = owned_provider,
            .review_context = context,
        };
    }

    pub fn deinit(self: *Request) void {
        std.crypto.secureZero(u8, self.review_context);
        self.allocator.free(self.review_context);
        if (self.owns_provider) self.provider.deinit();
        if (self.owns_publication) self.publication.deinit();
        self.* = undefined;
    }

    pub fn matchesScope(
        self: *const Request,
        repository: root_capability.Identity,
        target: *const committed.CommittedReviewTarget,
    ) bool {
        return self.publication.root.identity.eql(repository) and
            self.publication.target.eql(target);
    }

    fn takePublication(self: *Request) PublicationState {
        std.debug.assert(self.owns_publication);
        self.owns_publication = false;
        return self.publication;
    }

    fn takeProvider(self: *Request) ProviderRequest {
        std.debug.assert(self.owns_provider);
        self.owns_provider = false;
        return self.provider;
    }
};

pub const ReadyToPublish = struct {
    publication: PublicationState,
    plan: input_command.PlannedInput,
    candidates: producer.CandidateBatch,
    provenance: producer.ProviderProvenance,
    cleanup_warning: ?CleanupWarning = null,

    pub fn deinit(self: *ReadyToPublish) void {
        self.candidates.deinit();
        self.provenance.deinit();
        self.plan.deinit();
        self.publication.deinit();
        self.* = undefined;
    }
};

pub const ReviewResult = union(enum) {
    ready: ReadyToPublish,
    terminal: Terminal,

    pub fn deinit(self: *ReviewResult) void {
        switch (self.*) {
            .ready => |*value| value.deinit(),
            .terminal => {},
        }
        self.* = .{ .terminal = failedTerminal(.internal_error, null) };
    }
};

pub fn review(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
    control: process_runner.ProcessControl,
) ReviewResult {
    var owned = request;
    defer owned.deinit();
    if (controlTerminal(io, control)) |terminal| return .{ .terminal = terminal };
    const directory: git_command.DirectoryContext = .{
        .cwd = owned.publication.root.dir(),
        .environment = &owned.publication.environment,
    };
    const availability = git_review.checkTargetAvailability(allocator, io, directory, owned.publication.target) catch
        return failed(.repository_unavailable);
    switch (availability) {
        .availability => |value| if (value == .missing) return failed(.target_unavailable),
        .failure => return failed(.repository_unavailable),
    }
    var projection_result = git_review.materializeCommittedProjection(allocator, io, directory, owned.publication.target) catch
        return failed(.projection_failed);
    defer projection_result.deinit(allocator);
    const projection = switch (projection_result) {
        .projection => |*value| value,
        .failure => return failed(.projection_failed),
    };
    var violation: ?@import("limits.zig").Violation = null;
    var plan = input_command.planAlloc(allocator, io, directory, owned.publication.target, projection.patch_bytes, &violation) catch |err| return switch (err) {
        error.OutOfMemory => failed(.internal_error),
        error.LimitExceeded, error.ReviewUnitTooLarge, error.ReviewLineTooLarge => failed(.input_too_large),
        else => failed(.input_failed),
    };
    errdefer plan.deinit();
    if (plan.units.len == 0) {
        plan.deinit();
        return .{ .terminal = makeTerminal(.no_changes, null) };
    }
    if (controlTerminal(io, control)) |terminal| {
        plan.deinit();
        return .{ .terminal = terminal };
    }

    const provider_request = owned.takeProvider();
    var adapter_result = switch (provider_request) {
        .codex => |provider_value| codex.run(allocator, io, provider_value, .{
            .units = plan.units,
            .context = owned.review_context,
        }, control) catch {
            plan.deinit();
            return failed(.internal_error);
        },
    };
    defer adapter_result.deinit();
    if (mapAdapterTerminal(&adapter_result)) |resolved| {
        plan.deinit();
        return .{ .terminal = resolved };
    }
    const cleanup_warning = mapCleanupWarning(adapter_result.cleanup_warning);
    var adapter_output = switch (adapter_result.outcome) {
        .success => |value| blk: {
            adapter_result.outcome = .{ .failed = .invalid_provider_result };
            break :blk value;
        },
        .canceled, .timed_out, .failed => unreachable,
    };
    var verifier: GitVerifier = .{ .allocator = allocator, .io = io, .directory = directory };
    producer.validateCandidates(allocator, .{
        .summary = &plan.summary,
        .units = plan.units,
        .candidates = adapter_output.candidates.payloads,
    }, verifier.port()) catch {
        adapter_output.candidates.deinit();
        adapter_output.provenance.deinit();
        plan.deinit();
        return failedWithWarning(.invalid_candidates, cleanup_warning);
    };
    return .{ .ready = .{
        .publication = owned.takePublication(),
        .plan = plan,
        .candidates = adapter_output.candidates,
        .provenance = adapter_output.provenance,
        .cleanup_warning = cleanup_warning,
    } };
}

/// Consume an accepted handoff. This is the only entry which prepares an ID
/// or mutates the Review Store, and it never observes a post-accept cancel.
pub fn publishReady(allocator: std.mem.Allocator, io: std.Io, ready: ReadyToPublish) Terminal {
    var owned = ready;
    defer owned.deinit();
    const cleanup_warning = owned.cleanup_warning;
    const repository = repositoryContext(&owned.publication);
    const prepared = store_service.prepareWithRepository(
        allocator,
        io,
        &owned.publication.store,
        repository,
        owned.publication.repository_path,
    ) catch return failedTerminal(.store_prepare_failed, cleanup_warning);
    const binding = switch (prepared) {
        .success => |value| value,
        .failure => return failedTerminal(.store_prepare_failed, cleanup_warning),
    };
    const created_at = currentUtcSecond(io) orelse return failedTerminal(.artifact_failed, cleanup_warning);
    const provenance = owned.provenance.committedProducer();
    var verifier: GitVerifier = .{ .allocator = allocator, .io = io, .directory = .{
        .cwd = owned.publication.root.dir(),
        .environment = &owned.publication.environment,
    } };
    var artifacts = producer.buildAlloc(allocator, .{
        .summary = &owned.plan.summary,
        .units = owned.plan.units,
        .candidates = owned.candidates.payloads,
        .review_repository_id = binding.review_repository_id,
        .review_id = binding.review_id,
        .producer = provenance,
        .created_at = &created_at,
        .display = owned.publication.display,
    }, verifier.port()) catch return failedTerminal(.artifact_failed, cleanup_warning);
    defer artifacts.deinit(allocator);
    const publication = store_service.publishWithRepository(allocator, io, &owned.publication.store, repository, .{
        .repository_path = owned.publication.repository_path,
        .review_repository_id = binding.review_repository_id,
        .review_id = binding.review_id,
        .manifest_bytes = artifacts.manifest_bytes,
        .findings_bytes = artifacts.findings_bytes,
    }) catch return makeTerminal(.{ .outcome_unknown = binding.review_id }, cleanup_warning);
    switch (publication) {
        .success => {},
        .failure => return failedTerminal(.publish_failed, cleanup_warning),
    }
    var exact = store_service.readExactIdentityWithRepository(allocator, io, &owned.publication.store, repository, binding.review_id, .{
        .review_repository_id = binding.review_repository_id,
        .target = owned.plan.summary.target,
        .producer = provenance,
        .created_at = &created_at,
        .finding_count = artifacts.finding_count,
        .manifest_sha256 = artifacts.manifest_digest,
        .findings_sha256 = artifacts.findings_digest,
    }) catch return makeTerminal(.{ .outcome_unknown = binding.review_id }, cleanup_warning);
    defer exact.deinit(allocator);
    return switch (exact) {
        .exact => |value| makeTerminal(.{ .published = .{ .review_id = value.review_id, .finding_count = value.identity.finding_count } }, cleanup_warning),
        .failure => makeTerminal(.{ .outcome_unknown = binding.review_id }, cleanup_warning),
    };
}

fn repositoryContext(publication: *const PublicationState) store_service.RepositoryContext {
    return .{ .capability = &publication.root, .environment = &publication.environment };
}

const GitVerifier = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: git_command.DirectoryContext,

    fn port(self: *GitVerifier) producer.AnchorVerifier {
        return .{ .context = self, .verify_fn = verify };
    }

    fn verify(context: ?*anyopaque, target: *const committed.CommittedReviewTarget, anchor: committed.CodeAnchor) producer.VerifyError!void {
        const self: *GitVerifier = @ptrCast(@alignCast(context.?));
        var resolved = git_review.resolveCodeAnchor(self.allocator, self.io, self.directory, target.*, anchor) catch
            return error.OutOfMemory;
        defer resolved.deinit(self.allocator);
        if (resolved == .failure) return error.AnchorUnavailable;
    }
};

fn controlTerminal(io: std.Io, control: process_runner.ProcessControl) ?Terminal {
    if (control.cancellation) |cancellation| if (cancellation.requested()) return makeTerminal(.canceled, null);
    if (control.deadline) |deadline| {
        if (deadline.compare(.lte, std.Io.Clock.Timestamp.now(io, deadline.clock))) {
            return failedTerminal(.timed_out, null);
        }
    }
    return null;
}

fn mapCodexFailure(code: codex.FailureCode) FailureCode {
    return switch (code) {
        .internal_error => .internal_error,
        .input_too_large => .input_too_large,
        .provider_unavailable => .provider_unavailable,
        .provider_incompatible => .provider_incompatible,
        .provider_failed => .provider_failed,
        .invalid_provider_result => .invalid_provider_result,
    };
}

fn mapAdapterTerminal(result: *const codex.Result) ?Terminal {
    const cleanup_warning = mapCleanupWarning(result.cleanup_warning);
    return switch (result.outcome) {
        .success => null,
        .canceled => makeTerminal(.canceled, cleanup_warning),
        .timed_out => failedTerminal(.timed_out, cleanup_warning),
        .failed => |code| failedTerminal(mapCodexFailure(code), cleanup_warning),
    };
}

fn mapCleanupWarning(warning: ?codex.CleanupWarning) ?CleanupWarning {
    return if (warning) |value| switch (value) {
        .private_root_residue => .private_root_residue,
    } else null;
}

fn failed(code: FailureCode) ReviewResult {
    return failedWithWarning(code, null);
}

fn failedWithWarning(code: FailureCode, cleanup_warning: ?CleanupWarning) ReviewResult {
    return .{ .terminal = failedTerminal(code, cleanup_warning) };
}

fn failedTerminal(code: FailureCode, cleanup_warning: ?CleanupWarning) Terminal {
    return makeTerminal(.{ .failed = code }, cleanup_warning);
}

fn makeTerminal(outcome: TerminalOutcome, cleanup_warning: ?CleanupWarning) Terminal {
    return .{ .outcome = outcome, .cleanup_warning = cleanup_warning };
}

fn currentUtcSecond(io: std.Io) ?[20]u8 {
    const resolution = std.Io.Clock.real.resolution(io) catch return null;
    if (resolution.nanoseconds == 0) return null;
    const timestamp = std.Io.Clock.real.now(io);
    const value = std.math.cast(i64, @divFloor(timestamp.nanoseconds, std.time.ns_per_s)) orelse return null;
    if (value < 0 or value > 253_402_300_799) return null;
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(value) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds.getDaySeconds();
    var result: [20]u8 = undefined;
    const rendered = std.fmt.bufPrint(&result, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch return null;
    return if (rendered.len == result.len) result else null;
}

test "ReviewPipeline terminal taxonomy keeps prepublication and exact-ID uncertainty distinct" {
    const id = try committed.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000");
    const no_changes = makeTerminal(.no_changes, .private_root_residue);
    try std.testing.expect(no_changes.outcome == .no_changes);
    try std.testing.expectEqual(CleanupWarning.private_root_residue, no_changes.cleanup_warning.?);
    const uncertain = makeTerminal(.{ .outcome_unknown = id }, null);
    try std.testing.expect(uncertain.outcome.outcome_unknown.eql(id));
}

test "ReviewPipeline keeps a provider failure primary while exposing its cleanup warning" {
    const provider_result: codex.Result = .{
        .outcome = .{ .failed = .provider_unavailable },
        .cleanup_warning = .private_root_residue,
    };
    const resolved = mapAdapterTerminal(&provider_result).?;
    try std.testing.expect(resolved.outcome == .failed);
    try std.testing.expectEqual(FailureCode.provider_unavailable, resolved.outcome.failed);
    try std.testing.expectEqual(CleanupWarning.private_root_residue, resolved.cleanup_warning.?);
}

fn testTarget() !committed.CommittedReviewTarget {
    const oid = try committed.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    return .{ .object_format = .sha1, .source_kind = .branch_range, .base_oid = oid, .head_oid = oid, .diff_base_oid = oid };
}

fn testProvenance(
    allocator: std.mem.Allocator,
    requested_model: ?[]const u8,
    actual_model: ?[]const u8,
    cli_version: ?[]const u8,
) !producer.ProviderProvenance {
    const name = try allocator.dupe(u8, "codex");
    errdefer allocator.free(name);
    const requested = if (requested_model) |value| try allocator.dupe(u8, value) else null;
    errdefer if (requested) |value| allocator.free(value);
    const actual = if (actual_model) |value| try allocator.dupe(u8, value) else null;
    errdefer if (actual) |value| allocator.free(value);
    const version = if (cli_version) |value| try allocator.dupe(u8, value) else null;
    return .{
        .allocator = allocator,
        .name = name,
        .requested_model = requested,
        .actual_model = actual,
        .cli_version = version,
    };
}

test "ReviewPipeline consumes a canceled request before repository work" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .fromMode(0o700));
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    var repo_dir = try tmp.dir.openDir(io, "repo", .{});
    defer repo_dir.close(io);
    try repo_dir.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: missing\n" });
    const repo_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo_path);
    const store_path = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_path);
    var root = try root_capability.RootCapability.openCanonical(repo_path);
    defer root.deinit();
    var store = try store_service.ConfiguredStore.initConfigured(allocator, store_path);
    defer store.deinit(allocator);
    const provider_request: ProviderRequest = .{ .codex = try codex.Request.init(allocator, "/bin/false", "requested") };
    const request = try Request.init(allocator, root, null, &store, repo_path, try testTarget(), null, provider_request, "context");
    var canceled_generation: std.atomic.Value(u64) = .init(9);
    var result = review(allocator, io, request, .{ .cancellation = .{
        .canceled_generation = &canceled_generation,
        .generation = 9,
    } });
    defer result.deinit();
    try std.testing.expect(result == .terminal);
    try std.testing.expect(result.terminal.outcome == .canceled);
}

test "publishReady rejects a nonrepository before preparing an ID" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .fromMode(0o700));
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    var repo_dir = try tmp.dir.openDir(io, "repo", .{});
    defer repo_dir.close(io);
    try repo_dir.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: missing\n" });
    const repo_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo_path);
    const store_path = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_path);
    var publication_arena = std.heap.ArenaAllocator.init(allocator);
    const owned_path = try publication_arena.allocator().dupe(u8, repo_path);
    const root = try root_capability.RootCapability.openCanonical(repo_path);
    const environment_value = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    const store = try store_service.ConfiguredStore.initConfigured(allocator, store_path);
    const plan_arena = std.heap.ArenaAllocator.init(allocator);
    const candidate_arena = std.heap.ArenaAllocator.init(allocator);
    const ready: ReadyToPublish = .{
        .publication = .{
            .allocator = allocator,
            .arena = publication_arena,
            .root = root,
            .environment = environment_value,
            .store = store,
            .repository_path = owned_path,
            .target = try testTarget(),
            .display = null,
        },
        .plan = .{ .arena = plan_arena, .summary = .{
            .schema_version = 1,
            .target = try testTarget(),
            .projection_digest = committed.Sha256Digest.hash("projection"),
            .instruction_set_digest = committed.Sha256Digest.hash("instructions"),
            .unit_count = 0,
            .plan_digest = committed.Sha256Digest.hash("plan"),
            .limits = .v1,
        }, .units = &.{} },
        .candidates = .{ .arena = candidate_arena, .payloads = &.{} },
        .provenance = try testProvenance(allocator, "requested-only", null, null),
        .cleanup_warning = .private_root_residue,
    };
    const terminal = publishReady(allocator, io, ready);
    try std.testing.expect(terminal.outcome == .failed);
    try std.testing.expectEqual(FailureCode.store_prepare_failed, terminal.outcome.failed);
    try std.testing.expectEqual(CleanupWarning.private_root_residue, terminal.cleanup_warning.?);
}

fn runTestCommand(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
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
    if (result.term != .exited or result.term.exited != 0) return error.TestCommandFailed;
}

test "publishReady creates exact zero and nonzero publications and rejects a bad anchor" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .fromMode(0o700));
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runTestCommand(io, repo, &.{ "git", "init", "--initial-branch=main" });
    try repo.writeFile(io, .{ .sub_path = "sample.txt", .data = "base\n" });
    try runTestCommand(io, repo, &.{ "git", "add", "sample.txt" });
    try runTestCommand(io, repo, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try runTestCommand(io, repo, &.{ "git", "branch", "review-base", "HEAD" });
    try repo.writeFile(io, .{ .sub_path = "sample.txt", .data = "base\nhead\n" });
    try runTestCommand(io, repo, &.{ "git", "add", "sample.txt" });
    try runTestCommand(io, repo, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });

    const repo_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo_path);
    const store_path = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_path);
    var planning_root = try root_capability.RootCapability.openCanonical(repo_path);
    defer planning_root.deinit();
    var planning_environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer planning_environment.deinit();
    const directory: git_command.DirectoryContext = .{
        .cwd = planning_root.dir(),
        .environment = &planning_environment,
    };
    const target_result = try git_review.resolveTarget(allocator, io, directory, .{
        .source_kind = .branch_range,
        .base = "refs/heads/review-base",
        .head = "refs/heads/main",
    });
    const target = switch (target_result) {
        .target => |value| value,
        .failure => return error.TargetResolutionFailed,
    };
    var previous_id: ?committed.ReviewId = null;

    const Case = enum { zero, finding, invalid_anchor };
    inline for (.{ Case.zero, Case.finding, Case.invalid_anchor }) |case| {
        var projection_result = try git_review.materializeCommittedProjection(allocator, io, directory, target);
        defer projection_result.deinit(allocator);
        const projection = switch (projection_result) {
            .projection => |*value| value,
            .failure => return error.ProjectionFailed,
        };
        var violation: ?@import("limits.zig").Violation = null;
        const plan = try input_command.planAlloc(allocator, io, directory, target, projection.patch_bytes, &violation);
        try std.testing.expect(plan.units.len > 0);

        var candidate_arena = std.heap.ArenaAllocator.init(allocator);
        const payloads = try candidate_arena.allocator().alloc(protocol.FindingCandidatePayload, plan.units.len);
        for (payloads) |*payload| payload.* = .{ .findings = &.{} };
        if (case != .zero) {
            const location = if (case == .invalid_anchor)
                try protocol.LocationId.parse("a9999")
            else
                plan.units[0].locations[0].location_id;
            const findings = try candidate_arena.allocator().alloc(protocol.FindingCandidate, 1);
            findings[0] = .{
                .start_location = location,
                .end_location = location,
                .severity = .warning,
                .title = "Exact fixture finding",
                .body = "Publication retains the validated candidate.",
            };
            payloads[0] = .{ .findings = findings };
        }

        var publication_arena = std.heap.ArenaAllocator.init(allocator);
        const owned_path = try publication_arena.allocator().dupe(u8, repo_path);
        const publication_root = try planning_root.duplicate();
        const publication_environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
        const publication_store = try store_service.ConfiguredStore.initConfigured(allocator, store_path);
        const ready: ReadyToPublish = .{
            .publication = .{
                .allocator = allocator,
                .arena = publication_arena,
                .root = publication_root,
                .environment = publication_environment,
                .store = publication_store,
                .repository_path = owned_path,
                .target = target,
                .display = null,
            },
            .plan = plan,
            .candidates = .{ .arena = candidate_arena, .payloads = payloads },
            .provenance = if (case == .finding)
                try testProvenance(allocator, null, "trusted-actual", "999.0")
            else
                try testProvenance(allocator, "requested-only", null, null),
            .cleanup_warning = if (case == .finding) .private_root_residue else null,
        };
        const terminal = publishReady(allocator, io, ready);
        if (case == .invalid_anchor) {
            try std.testing.expect(terminal.outcome == .failed);
            try std.testing.expectEqual(FailureCode.artifact_failed, terminal.outcome.failed);
            continue;
        }
        try std.testing.expect(terminal.outcome == .published);
        try std.testing.expectEqual(@as(u32, if (case == .finding) 1 else 0), terminal.outcome.published.finding_count);
        try std.testing.expectEqual(case == .finding, terminal.cleanup_warning != null);
        if (previous_id) |id| try std.testing.expect(!id.eql(terminal.outcome.published.review_id));
        previous_id = terminal.outcome.published.review_id;
    }
}
