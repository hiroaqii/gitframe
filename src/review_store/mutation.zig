//! Store-owned mutable Review Run lifecycle.
//!
//! Callers bind requests to exact repository/run/target/digest values. This
//! module alone assigns draft revisions and completion timestamps, and it
//! exposes canonical files only through namespace staging plus atomic rename.

const std = @import("std");
const builtin = @import("builtin");
const committed_review = @import("../committed_review.zig");
const durable = @import("../fs/durable.zig");
const capability = @import("capability.zig");
const registry = @import("registry.zig");
const run_artifacts = @import("run.zig");
const store_path = @import("path.zig");

pub const Failure = enum { conflict, draft_required, already_completed, binding_changed, run_invalid, clock_unavailable, unsupported, io_failed };

pub const RunBinding = struct {
    review_repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    target: committed_review.CommittedReviewTarget,
    findings_digest: committed_review.Sha256Digest,

    pub fn eql(self: RunBinding, other: RunBinding) bool {
        return self.review_repository_id.eql(other.review_repository_id) and
            self.review_id.eql(other.review_id) and
            self.target.eql(&other.target) and
            self.findings_digest.eql(other.findings_digest);
    }
};

pub const DraftRequest = struct {
    binding: RunBinding,
    /// Zero means that no draft exists. The Store assigns the next revision.
    expected_revision: u64,
    summary: ?[]const u8,
    finding_dispositions: []const committed_review.FindingDisposition,
    anchored_notes: []const committed_review.AnchoredNote,
};

pub const ResultRequest = struct { binding: RunBinding, expected_revision: u64, decision: committed_review.ReviewResultValue };

pub const DraftCommit = struct {
    revision: u64,
    canonical_bytes: []u8,

    pub fn deinit(self: *DraftCommit, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_bytes);
        self.* = undefined;
    }
};

pub const ResultCommit = struct {
    revision: u64,
    completed_at: [20]u8,
    canonical_bytes: []u8,

    pub fn deinit(self: *ResultCommit, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_bytes);
        self.* = undefined;
    }
};

pub const DraftResult = union(enum) {
    committed: DraftCommit,
    failure: Failure,

    pub fn deinit(self: *DraftResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .committed => |*value| value.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .io_failed };
    }
};

pub const ResultResult = union(enum) {
    committed: ResultCommit,
    failure: Failure,

    pub fn deinit(self: *ResultResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .committed => |*value| value.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .io_failed };
    }
};

const HeldLock = struct {
    file: @FieldType(durable.FileAcquisition, "file"),
    io: std.Io,
    root_metadata: capability.Metadata,

    fn deinit(self: *HeldLock) void {
        self.file.unlock(self.io);
        self.file.deinit();
        self.* = undefined;
    }
};

const LockedRun = struct {
    root: capability.StoreRootCapability,
    namespace: capability.DirectoryCapability,
    run: capability.DirectoryCapability,
    loaded: run_artifacts.LoadedRunArtifacts,

    fn deinit(self: *LockedRun, allocator: std.mem.Allocator) void {
        self.loaded.deinit(allocator);
        self.run.deinit();
        self.namespace.deinit();
        self.root.deinit();
        self.* = undefined;
    }
};

const OpenResult = union(enum) { opened: LockedRun, failure: Failure };

const Clock = struct {
    context: ?*anyopaque = null,
    sample_fn: *const fn (?*anyopaque, std.Io) ?i64 = sampleRealClock,

    fn sample(self: Clock, io: std.Io) ?i64 {
        return self.sample_fn(self.context, io);
    }
};

/// Persist one complete draft snapshot with revision compare-and-swap.
pub fn saveDraft(allocator: std.mem.Allocator, io: std.Io, resolved_store: *const store_path.Resolved, request: DraftRequest) std.mem.Allocator.Error!DraftResult {
    const store_root = switch (resolved_store.*) {
        .available => |value| value,
        .unavailable => return .{ .failure = .io_failed },
    };
    return saveDraftWith(allocator, io, store_root, request, .{});
}

fn saveDraftWith(allocator: std.mem.Allocator, io: std.Io, store_root: []const u8, request: DraftRequest, observer: durable.Observer) std.mem.Allocator.Error!DraftResult {
    var lock = switch (acquireRunLock(io, store_root, request.binding)) {
        .lock => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    defer lock.deinit();

    var opened = try openLockedRun(allocator, io, store_root, request.binding, lock.root_metadata);
    var run = switch (opened) {
        .opened => |*value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    defer run.deinit(allocator);

    run.loaded.state.admitDraftMutation() catch return .{ .failure = .already_completed };
    const current_revision = if (run.loaded.draft) |*draft| draft.value.revision else 0;
    if (current_revision != request.expected_revision) return .{ .failure = .conflict };
    const next_revision = std.math.add(u64, current_revision, 1) catch return .{ .failure = .conflict };
    const draft: committed_review.ReviewDraftState = .{
        .schema_version = committed_review.limits.schema_version,
        .review_id = request.binding.review_id,
        .target = request.binding.target,
        .findings_digest = request.binding.findings_digest,
        .revision = next_revision,
        .summary = request.summary,
        .finding_dispositions = request.finding_dispositions,
        .anchored_notes = request.anchored_notes,
    };
    draft.validateAgainst(&run.loaded.findings.value, run.loaded.manifest.value.findings_digest) catch
        return .{ .failure = .run_invalid };
    const bytes = draft.writeCanonical(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .run_invalid },
    };
    var bytes_owned = true;
    defer if (bytes_owned) allocator.free(bytes);

    writeMutationFile(
        io,
        run.namespace,
        run.run,
        request.binding.review_id,
        .draft,
        "review_state.json",
        bytes,
        .replace,
        observer,
    ) catch |err| return .{ .failure = mapMutationError(err) };
    bytes_owned = false;
    return .{ .committed = .{ .revision = next_revision, .canonical_bytes = bytes } };
}

/// Create the terminal result from the exact latest draft and one real-clock
/// sample. Existing result authority is never replaced.
pub fn createResult(allocator: std.mem.Allocator, io: std.Io, resolved_store: *const store_path.Resolved, request: ResultRequest) std.mem.Allocator.Error!ResultResult {
    const store_root = switch (resolved_store.*) {
        .available => |value| value,
        .unavailable => return .{ .failure = .io_failed },
    };
    return createResultWith(allocator, io, store_root, request, .{}, .{});
}

fn createResultWith(allocator: std.mem.Allocator, io: std.Io, store_root: []const u8, request: ResultRequest, clock: Clock, observer: durable.Observer) std.mem.Allocator.Error!ResultResult {
    var lock = switch (acquireRunLock(io, store_root, request.binding)) {
        .lock => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    defer lock.deinit();

    var opened = try openLockedRun(allocator, io, store_root, request.binding, lock.root_metadata);
    var run = switch (opened) {
        .opened => |*value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    defer run.deinit(allocator);

    run.loaded.state.admitResultCreation() catch |err| return .{ .failure = switch (err) {
        error.DraftRequired => .draft_required,
        error.AlreadyCompleted => .already_completed,
    } };
    const draft = if (run.loaded.draft) |*value| &value.value else return .{ .failure = .draft_required };
    if (draft.revision != request.expected_revision) return .{ .failure = .conflict };
    const completed_at = formatUtcSecond(clock.sample(io) orelse return .{ .failure = .clock_unavailable }) orelse
        return .{ .failure = .clock_unavailable };
    const result: committed_review.RevisionReviewResult = .{
        .schema_version = committed_review.limits.schema_version,
        .review_id = request.binding.review_id,
        .target = request.binding.target,
        .findings_digest = request.binding.findings_digest,
        .result = request.decision,
        .completed_at = &completed_at,
        .summary = draft.summary,
        .finding_dispositions = draft.finding_dispositions,
        .anchored_notes = draft.anchored_notes,
    };
    result.validateSubmitSnapshot(
        draft,
        &run.loaded.findings.value,
        run.loaded.manifest.value.findings_digest,
    ) catch return .{ .failure = .run_invalid };
    const bytes = result.writeCanonical(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .run_invalid },
    };
    var bytes_owned = true;
    defer if (bytes_owned) allocator.free(bytes);

    writeMutationFile(
        io,
        run.namespace,
        run.run,
        request.binding.review_id,
        .result,
        "result.json",
        bytes,
        .no_replace,
        observer,
    ) catch |err| {
        if (err == error.PathAlreadyExists) {
            var reconciliation = try reopenRun(allocator, io, run.namespace, request.binding);
            defer reconciliation.deinit(allocator);
            return switch (reconciliation) {
                .loaded => |*loaded| if (loaded.state == .completed)
                    .{ .failure = .already_completed }
                else
                    .{ .failure = .run_invalid },
                .invalid => .{ .failure = .run_invalid },
            };
        }
        return .{ .failure = mapMutationError(err) };
    };
    bytes_owned = false;
    return .{ .committed = .{
        .revision = draft.revision,
        .completed_at = completed_at,
        .canonical_bytes = bytes,
    } };
}

const LockResult = union(enum) { lock: HeldLock, failure: Failure };

fn acquireRunLock(io: std.Io, store_root: []const u8, binding: RunBinding) LockResult {
    var root = capability.StoreRootCapability.openCanonical(store_root) catch |err|
        return .{ .failure = mapOpenError(err) };
    defer root.deinit();
    var locks = root.directory.openDirectory(".locks") catch |err|
        return .{ .failure = mapBindingOpenError(err) };
    defer locks.deinit();
    const repository_text = binding.review_repository_id.canonical();
    var repository_locks = locks.openDirectory(&repository_text) catch |err|
        return .{ .failure = mapBindingOpenError(err) };
    defer repository_locks.deinit();
    const review_text = binding.review_id.canonical();
    var lock_name_buffer: [41]u8 = undefined;
    const lock_name = std.fmt.bufPrint(&lock_name_buffer, "{s}.lock", .{review_text}) catch
        return .{ .failure = .io_failed };
    const acquired = switch (capability.acquireRegularFile(repository_locks, lock_name, .{})) {
        .not_completed => |err| return .{ .failure = mapMutationError(err) },
        .completed => |result| result,
    };
    var file = acquired.value.file;
    if (acquired.after_error) |err| {
        file.deinit();
        return .{ .failure = mapMutationError(err) };
    }
    file.lock(io, .exclusive) catch |err| {
        file.deinit();
        return .{ .failure = mapMutationError(err) };
    };
    return .{ .lock = .{
        .file = file,
        .io = io,
        .root_metadata = root.directory.metadata,
    } };
}

fn openLockedRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_root: []const u8,
    binding: RunBinding,
    expected_root: capability.Metadata,
) std.mem.Allocator.Error!OpenResult {
    var root = capability.StoreRootCapability.openCanonical(store_root) catch |err|
        return .{ .failure = mapOpenError(err) };
    var root_owned = true;
    defer if (root_owned) root.deinit();
    if (!root.directory.metadata.sameObject(expected_root)) {
        return .{ .failure = .binding_changed };
    }

    var current_registry = try registry.read(allocator, io, root.directory);
    defer current_registry.deinit();
    switch (current_registry) {
        .registry => |*parsed| {
            var found = false;
            for (parsed.bindings) |candidate| {
                if (candidate.review_repository_id.eql(binding.review_repository_id)) {
                    found = true;
                    break;
                }
            }
            if (!found) return .{ .failure = .binding_changed };
        },
        .missing => return .{ .failure = .binding_changed },
        .invalid => return .{ .failure = .run_invalid },
        .unavailable => return .{ .failure = .io_failed },
    }

    const repository_text = binding.review_repository_id.canonical();
    var namespace = root.directory.openDirectory(&repository_text) catch |err|
        return .{ .failure = mapBindingOpenError(err) };
    var namespace_owned = true;
    defer if (namespace_owned) namespace.deinit();
    const review_text = binding.review_id.canonical();
    var run = namespace.openDirectory(&review_text) catch |err|
        return .{ .failure = mapBindingOpenError(err) };
    var run_owned = true;
    defer if (run_owned) run.deinit();

    const loaded_result = try reopenRun(allocator, io, namespace, binding);
    const loaded = switch (loaded_result) {
        .loaded => |value| value,
        .invalid => return .{ .failure = .run_invalid },
    };
    var current_run = namespace.openDirectory(&review_text) catch |err| {
        var owned = loaded;
        owned.deinit(allocator);
        return .{ .failure = mapBindingOpenError(err) };
    };
    defer current_run.deinit();
    if (!current_run.metadata.sameObject(run.metadata)) {
        var owned = loaded;
        owned.deinit(allocator);
        return .{ .failure = .binding_changed };
    }
    if (!loaded.manifest.value.target.eql(&binding.target) or
        !loaded.manifest.value.findings_digest.eql(binding.findings_digest))
    {
        var owned = loaded;
        owned.deinit(allocator);
        return .{ .failure = .binding_changed };
    }

    root_owned = false;
    namespace_owned = false;
    run_owned = false;
    return .{ .opened = .{
        .root = root,
        .namespace = namespace,
        .run = run,
        .loaded = loaded,
    } };
}

fn reopenRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    namespace: capability.DirectoryCapability,
    binding: RunBinding,
) std.mem.Allocator.Error!run_artifacts.LoadResult {
    var budget: run_artifacts.ArtifactBudget = .{};
    return run_artifacts.loadValidated(
        allocator,
        io,
        namespace,
        binding.review_repository_id,
        binding.review_id,
        &budget,
    );
}

const RenameMode = enum { replace, no_replace };

fn writeMutationFile(
    io: std.Io,
    namespace: capability.DirectoryCapability,
    run: capability.DirectoryCapability,
    review_id: committed_review.ReviewId,
    kind: store_path.NamespaceTempKind,
    final_name: []const u8,
    bytes: []const u8,
    rename_mode: RenameMode,
    observer: durable.Observer,
) !void {
    var formatted: store_path.NamespaceTempName.Formatted = undefined;
    var file_value: ?@FieldType(durable.FileAcquisition, "file") = null;
    var create_after_error: ?anyerror = null;
    for (0..8) |_| {
        var token: [16]u8 = undefined;
        try io.randomSecure(&token);
        formatted = (store_path.NamespaceTempName{
            .kind = kind,
            .review_id = review_id,
            .token = token,
        }).format();
        switch (capability.createFile(namespace, formatted.slice(), observer)) {
            .not_completed => |err| if (err == error.PathAlreadyExists) continue else return err,
            .completed => |result| {
                file_value = result.value;
                create_after_error = result.after_error;
            },
        }
        break;
    }
    var file = file_value orelse return error.ConcurrentStagingConflict;
    const temp_name = formatted.slice();
    var renamed = false;
    defer if (!renamed) cleanupOwnTemp(io, namespace, temp_name);
    defer file.deinit();
    if (create_after_error) |err| return err;

    try completedVoid(durable.writeAll(io, file, bytes, observer));
    try completedVoid(durable.syncFile(io, file, observer));
    try completedVoid(capability.syncDirectory(io, namespace, observer));
    const moved = switch (rename_mode) {
        .replace => capability.moveReplacing(io, namespace, temp_name, run, final_name, observer),
        .no_replace => capability.movePreserving(io, namespace, temp_name, run, final_name, observer),
    };
    switch (moved) {
        .not_completed => |err| return err,
        .completed => |result| {
            renamed = true;
            if (result.after_error) |err| return err;
        },
    }
    try completedVoid(capability.syncDirectory(io, run, observer));
    try completedVoid(capability.syncDirectory(io, namespace, observer));
}

fn cleanupOwnTemp(io: std.Io, namespace: capability.DirectoryCapability, name: []const u8) void {
    switch (capability.removeFile(io, namespace, name, .{})) {
        .not_completed => return,
        .completed => {},
    }
    _ = capability.syncDirectory(io, namespace, .{});
}

fn completedVoid(outcome: durable.Outcome(void)) !void {
    switch (outcome) {
        .not_completed => |err| return err,
        .completed => |result| if (result.after_error) |err| return err,
    }
}

fn sampleRealClock(_: ?*anyopaque, io: std.Io) ?i64 {
    const resolution = std.Io.Clock.real.resolution(io) catch return null;
    if (resolution.nanoseconds == 0) return null;
    const timestamp = std.Io.Clock.real.now(io);
    return std.math.cast(i64, @divFloor(timestamp.nanoseconds, std.time.ns_per_s));
}

fn formatUtcSecond(value: i64) ?[20]u8 {
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
    if (rendered.len != result.len) return null;
    return result;
}

fn mapOpenError(err: anyerror) Failure {
    if (err == error.UnsupportedPlatform or err == error.UnsupportedFilesystem) return .unsupported;
    if (err == error.FileNotFound) return .binding_changed;
    return if (isUnsafeError(err)) .run_invalid else .io_failed;
}

fn mapBindingOpenError(err: anyerror) Failure {
    if (err == error.UnsupportedPlatform or err == error.UnsupportedFilesystem) return .unsupported;
    if (err == error.FileNotFound) return .binding_changed;
    return if (isUnsafeError(err)) .run_invalid else .io_failed;
}

fn mapMutationError(err: anyerror) Failure {
    if (err == error.UnsupportedPlatform or
        err == error.UnsupportedFilesystem or
        err == error.OperationUnsupported) return .unsupported;
    return if (isUnsafeError(err)) .run_invalid else .io_failed;
}

fn isUnsafeError(err: anyerror) bool {
    return switch (err) {
        error.WrongType,
        error.WrongOwner,
        error.WrongMode,
        error.CrossDevice,
        error.MultipleLinks,
        error.SymLinkLoop,
        error.NotDir,
        error.InvalidChildName,
        => true,
        else => false,
    };
}

test "review state persistence draft CAS and trusted-clock result round trip" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestFixture.init(allocator, io, tmp.dir, "store");
    defer fixture.deinit(allocator);

    var clock_value = try committed_review.strict_json.timestampToUnixSeconds("2026-05-03T00:00:00Z");
    const fake_clock: Clock = .{ .context = &clock_value, .sample_fn = &fixedClock };
    var missing_draft = try createResultWith(
        allocator,
        io,
        fixture.store_root,
        fixture.resultRequest(0, .approved),
        fake_clock,
        .{},
    );
    defer missing_draft.deinit(allocator);
    try std.testing.expectEqual(Failure.draft_required, missing_draft.failure);

    var first = try saveDraftAt(allocator, io, fixture.store_root, fixture.draftRequest(0, "first"));
    defer first.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), first.committed.revision);
    var parsed_first = try committed_review.ReviewDraftState.parseStrict(allocator, first.committed.canonical_bytes);
    defer parsed_first.deinit();
    try std.testing.expectEqualStrings("first", parsed_first.value.summary.?);

    var stale = try saveDraftAt(allocator, io, fixture.store_root, fixture.draftRequest(0, "stale"));
    defer stale.deinit(allocator);
    try std.testing.expectEqual(Failure.conflict, stale.failure);

    var second = try saveDraftAt(allocator, io, fixture.store_root, fixture.draftRequest(1, "second"));
    defer second.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), second.committed.revision);

    var wrong_revision = try createResultWith(
        allocator,
        io,
        fixture.store_root,
        fixture.resultRequest(1, .approved),
        fake_clock,
        .{},
    );
    defer wrong_revision.deinit(allocator);
    try std.testing.expectEqual(Failure.conflict, wrong_revision.failure);

    var unavailable_clock = try createResultWith(
        allocator,
        io,
        fixture.store_root,
        fixture.resultRequest(2, .approved),
        .{ .sample_fn = &missingClock },
        .{},
    );
    defer unavailable_clock.deinit(allocator);
    try std.testing.expectEqual(Failure.clock_unavailable, unavailable_clock.failure);

    var completed = try createResultWith(
        allocator,
        io,
        fixture.store_root,
        fixture.resultRequest(2, .approved),
        fake_clock,
        .{},
    );
    defer completed.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), completed.committed.revision);
    try std.testing.expectEqualStrings("2026-05-03T00:00:00Z", &completed.committed.completed_at);
    var parsed_result = try committed_review.RevisionReviewResult.parseStrict(allocator, completed.committed.canonical_bytes);
    defer parsed_result.deinit();
    try std.testing.expectEqualStrings("second", parsed_result.value.summary.?);

    var frozen = try saveDraftAt(allocator, io, fixture.store_root, fixture.draftRequest(2, "third"));
    defer frozen.deinit(allocator);
    try std.testing.expectEqual(Failure.already_completed, frozen.failure);
}

fn saveDraftAt(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_root: []const u8,
    request: DraftRequest,
) std.mem.Allocator.Error!DraftResult {
    return saveDraftWith(allocator, io, store_root, request, .{});
}

test "review state persistence fault boundaries leave old or new byte-complete authority" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]MutationFaultCase{
        .{ .operation = .create_file, .edge = .after },
        .{ .operation = .sync_file, .edge = .before },
        .{ .operation = .sync_file, .edge = .after },
        .{ .operation = .sync_directory, .edge = .before, .occurrence = 0 },
        .{ .operation = .sync_directory, .edge = .after, .occurrence = 0 },
        .{ .operation = .rename_replace, .edge = .before, .rename = true },
        .{ .operation = .rename_replace, .edge = .after, .rename = true, .committed = true },
        .{ .operation = .sync_directory, .edge = .before, .occurrence = 1, .committed = true },
        .{ .operation = .sync_directory, .edge = .after, .occurrence = 1, .committed = true },
        .{ .operation = .sync_directory, .edge = .before, .occurrence = 2, .committed = true },
        .{ .operation = .sync_directory, .edge = .after, .occurrence = 2, .committed = true },
    };
    for (cases, 0..) |case, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "store-{d}", .{index});
        var fixture = try TestFixture.init(allocator, io, tmp.dir, name);
        defer fixture.deinit(allocator);
        var injected = TestStepObserver{ .selected = case.step(.rename_replace), .occurrence = case.occurrence };
        var result = try saveDraftWith(
            allocator,
            io,
            fixture.store_root,
            fixture.draftRequest(0, "faulted"),
            injected.observer(),
        );
        defer result.deinit(allocator);
        try std.testing.expectEqual(Failure.io_failed, result.failure);

        var reopened = try fixture.reopen(allocator, io);
        defer reopened.deinit(allocator);
        try std.testing.expect(injected.fired);
        if (case.committed) {
            try std.testing.expectEqual(committed_review.ReviewRunState.draft, reopened.loaded.state);
            try std.testing.expectEqualStrings("faulted", reopened.loaded.draft.?.value.summary.?);
        } else {
            try std.testing.expectEqual(committed_review.ReviewRunState.new, reopened.loaded.state);
        }
        try fixture.expectNoOwnTemp(io, .draft);
    }

    for (cases, 0..) |case, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "result-store-{d}", .{index});
        var fixture = try TestFixture.init(allocator, io, tmp.dir, name);
        defer fixture.deinit(allocator);
        var draft = try saveDraftAt(allocator, io, fixture.store_root, fixture.draftRequest(0, "terminal"));
        defer draft.deinit(allocator);
        var injected = TestStepObserver{ .selected = case.step(.rename_preserve), .occurrence = case.occurrence };
        var clock_value = try committed_review.strict_json.timestampToUnixSeconds("2026-05-03T00:00:00Z");
        var result = try createResultWith(
            allocator,
            io,
            fixture.store_root,
            fixture.resultRequest(1, .approved),
            .{ .context = &clock_value, .sample_fn = &fixedClock },
            injected.observer(),
        );
        defer result.deinit(allocator);
        try std.testing.expectEqual(Failure.io_failed, result.failure);

        var reopened = try fixture.reopen(allocator, io);
        defer reopened.deinit(allocator);
        try std.testing.expect(injected.fired);
        if (case.committed) {
            try std.testing.expectEqual(committed_review.ReviewRunState.completed, reopened.loaded.state);
            try std.testing.expectEqual(committed_review.ReviewResultValue.approved, reopened.loaded.result.?.value.result);
            try std.testing.expectEqualStrings("terminal", reopened.loaded.result.?.value.summary.?);
        } else {
            try std.testing.expectEqual(committed_review.ReviewRunState.draft, reopened.loaded.state);
            try std.testing.expectEqualStrings("terminal", reopened.loaded.draft.?.value.summary.?);
        }
        try fixture.expectNoOwnTemp(io, .result);
    }
}

test "review state persistence result no-replace reconciles winner and preserves foreign orphan" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestFixture.init(allocator, io, tmp.dir, "store");
    defer fixture.deinit(allocator);
    var draft = try saveDraftAt(allocator, io, fixture.store_root, fixture.draftRequest(0, "ready"));
    defer draft.deinit(allocator);

    const orphan_token = [_]u8{0xaa} ** 16;
    const orphan_name = (store_path.NamespaceTempName{
        .kind = .result,
        .review_id = fixture.binding.review_id,
        .token = orphan_token,
    }).format();
    try fixture.namespace.writeFile(io, .{
        .sub_path = orphan_name.slice(),
        .data = "foreign orphan",
        .flags = .{ .permissions = .fromMode(0o600) },
    });

    const winner = committed_review.RevisionReviewResult{
        .schema_version = 1,
        .review_id = fixture.binding.review_id,
        .target = fixture.binding.target,
        .findings_digest = fixture.binding.findings_digest,
        .result = .approved,
        .completed_at = "2026-08-21T00:00:00Z",
        .summary = "ready",
        .finding_dispositions = &.{},
        .anchored_notes = &.{},
    };
    const winner_bytes = try winner.writeCanonical(allocator);
    defer allocator.free(winner_bytes);
    var race = ResultRace{
        .io = io,
        .run = fixture.run,
        .winner_bytes = winner_bytes,
    };
    var clock_value = try committed_review.strict_json.timestampToUnixSeconds("2026-05-03T00:00:00Z");
    var result = try createResultWith(
        allocator,
        io,
        fixture.store_root,
        fixture.resultRequest(1, .needs_changes),
        .{ .context = &clock_value, .sample_fn = &fixedClock },
        .{ .context = &race, .observe_fn = &ResultRace.observe },
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(Failure.already_completed, result.failure);
    try fixture.namespace.access(io, orphan_name.slice(), .{});
    try fixture.expectNoOwnTempExcept(io, .result, orphan_name.slice());

    var reopened = try fixture.reopen(allocator, io);
    defer reopened.deinit(allocator);
    try std.testing.expectEqual(committed_review.ReviewRunState.completed, reopened.loaded.state);
    try std.testing.expectEqual(committed_review.ReviewResultValue.approved, reopened.loaded.result.?.value.result);

    var invalid_fixture = try TestFixture.init(allocator, io, tmp.dir, "invalid-store");
    defer invalid_fixture.deinit(allocator);
    var invalid_draft = try saveDraftAt(
        allocator,
        io,
        invalid_fixture.store_root,
        invalid_fixture.draftRequest(0, "dirty"),
    );
    defer invalid_draft.deinit(allocator);
    var invalid_race = ResultRace{
        .io = io,
        .run = invalid_fixture.run,
        .winner_bytes = "{}\n",
    };
    var invalid_clock = try committed_review.strict_json.timestampToUnixSeconds("2026-05-03T00:00:00Z");
    var invalid_result = try createResultWith(
        allocator,
        io,
        invalid_fixture.store_root,
        invalid_fixture.resultRequest(1, .approved),
        .{ .context = &invalid_clock, .sample_fn = &fixedClock },
        .{ .context = &invalid_race, .observe_fn = &ResultRace.observe },
    );
    defer invalid_result.deinit(allocator);
    try std.testing.expectEqual(Failure.run_invalid, invalid_result.failure);
    try invalid_fixture.expectNoOwnTemp(io, .result);
    var invalid_reopen = try invalid_fixture.reopen(allocator, io);
    defer invalid_reopen.deinit(allocator);
    try std.testing.expect(invalid_reopen == .invalid);
}

fn fixedClock(context: ?*anyopaque, _: std.Io) ?i64 {
    const value: *i64 = @ptrCast(@alignCast(context.?));
    return value.*;
}

fn missingClock(_: ?*anyopaque, _: std.Io) ?i64 {
    return null;
}

const MutationFaultCase = struct {
    operation: durable.Operation,
    edge: durable.Edge,
    occurrence: usize = 0,
    rename: bool = false,
    committed: bool = false,

    fn step(self: @This(), rename_operation: durable.Operation) durable.Step {
        return .{ .operation = if (self.rename) rename_operation else self.operation, .edge = self.edge };
    }
};

const TestStepObserver = struct {
    selected: durable.Step,
    occurrence: usize,
    seen: usize = 0,
    fired: bool = false,

    fn observe(context: ?*anyopaque, step: durable.Step) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.selected.operation != step.operation or self.selected.edge != step.edge) return;
        defer self.seen += 1;
        if (self.seen != self.occurrence) return;
        self.fired = true;
        return error.InjectedFault;
    }

    fn observer(self: *@This()) durable.Observer {
        return .{ .context = self, .observe_fn = observe };
    }
};

const ResultRace = struct {
    io: std.Io,
    run: std.Io.Dir,
    winner_bytes: []const u8,
    fired: bool = false,

    fn observe(context: ?*anyopaque, step: durable.Step) !void {
        const self: *ResultRace = @ptrCast(@alignCast(context.?));
        if (self.fired or step.operation != .rename_preserve or step.edge != .before) return;
        self.fired = true;
        try self.run.writeFile(self.io, .{
            .sub_path = "result.json",
            .data = self.winner_bytes,
            .flags = .{ .permissions = .fromMode(0o600) },
        });
    }
};

const TestFixture = struct {
    store_root: [:0]u8,
    store: std.Io.Dir,
    namespace: std.Io.Dir,
    run: std.Io.Dir,
    binding: RunBinding,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent: std.Io.Dir,
        name: []const u8,
    ) !TestFixture {
        const repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
        const review_id = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
        const oid = try committed_review.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
        const target: committed_review.CommittedReviewTarget = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = oid,
            .head_oid = oid,
            .diff_base_oid = oid,
        };
        try parent.createDir(io, name, .fromMode(0o700));
        var store = try parent.openDir(io, name, .{});
        errdefer store.close(io);
        try store.createDir(io, ".locks", .fromMode(0o700));
        var locks = try store.openDir(io, ".locks", .{});
        defer locks.close(io);
        const repository_text = repository_id.canonical();
        try locks.createDir(io, &repository_text, .fromMode(0o700));
        try store.createDir(io, &repository_text, .fromMode(0o700));
        var namespace = try store.openDir(io, &repository_text, .{});
        errdefer namespace.close(io);
        const review_text = review_id.canonical();
        try namespace.createDir(io, &review_text, .fromMode(0o700));
        var run = try namespace.openDir(io, &review_text, .{});
        errdefer run.close(io);

        const finding_set: committed_review.FindingSet = .{
            .schema_version = 1,
            .review_id = review_id,
            .created_at = "2026-08-21T00:00:00Z",
            .target = target,
            .producer = .{ .name = "test" },
            .findings = &.{},
        };
        const findings_bytes = try finding_set.writeCanonical(allocator);
        defer allocator.free(findings_bytes);
        const digest = committed_review.Sha256Digest.hash(findings_bytes);
        const manifest: committed_review.ReviewRunManifest = .{
            .schema_version = 1,
            .review_id = review_id,
            .review_repository_id = repository_id,
            .target = target,
            .created_at = finding_set.created_at,
            .display = null,
            .finding_count = 0,
            .producer = finding_set.producer,
            .findings_digest = digest,
        };
        const manifest_bytes = try manifest.writeCanonical(allocator);
        defer allocator.free(manifest_bytes);
        try writePrivate(io, run, "manifest.json", manifest_bytes);
        try writePrivate(io, run, "findings.json", findings_bytes);

        const path = try parent.realPathFileAlloc(io, name, allocator);
        errdefer allocator.free(path);
        const diagnostic = try registry.diagnosticPath("/test/repository");
        const registry_bytes = try registry.writeCanonicalAlloc(allocator, &.{.{
            .review_repository_id = repository_id,
            .locator = .{ .device = 7, .inode = 11 },
            .canonical_path = diagnostic,
            .last_seen_path = diagnostic,
        }});
        defer allocator.free(registry_bytes);
        try writePrivate(io, store, "registry.json", registry_bytes);
        return .{
            .store_root = path,
            .store = store,
            .namespace = namespace,
            .run = run,
            .binding = .{
                .review_repository_id = repository_id,
                .review_id = review_id,
                .target = target,
                .findings_digest = digest,
            },
        };
    }

    fn deinit(self: *TestFixture, allocator: std.mem.Allocator) void {
        self.run.close(std.testing.io);
        self.namespace.close(std.testing.io);
        self.store.close(std.testing.io);
        allocator.free(self.store_root);
        self.* = undefined;
    }

    fn draftRequest(self: *const TestFixture, expected_revision: u64, summary: []const u8) DraftRequest {
        return .{
            .binding = self.binding,
            .expected_revision = expected_revision,
            .summary = summary,
            .finding_dispositions = &.{},
            .anchored_notes = &.{},
        };
    }

    fn resultRequest(
        self: *const TestFixture,
        expected_revision: u64,
        decision: committed_review.ReviewResultValue,
    ) ResultRequest {
        return .{ .binding = self.binding, .expected_revision = expected_revision, .decision = decision };
    }

    fn reopen(self: *const TestFixture, allocator: std.mem.Allocator, io: std.Io) !run_artifacts.LoadResult {
        var root = try capability.StoreRootCapability.openCanonical(self.store_root);
        defer root.deinit();
        const repository_text = self.binding.review_repository_id.canonical();
        var namespace = try root.directory.openDirectory(&repository_text);
        defer namespace.deinit();
        return reopenRun(allocator, io, namespace, self.binding);
    }

    fn expectNoOwnTemp(self: *const TestFixture, io: std.Io, kind: store_path.NamespaceTempKind) !void {
        return self.expectNoOwnTempExcept(io, kind, "");
    }

    fn expectNoOwnTempExcept(
        self: *const TestFixture,
        io: std.Io,
        kind: store_path.NamespaceTempKind,
        exception: []const u8,
    ) !void {
        const repository_text = self.binding.review_repository_id.canonical();
        var iterable = try self.store.openDir(io, &repository_text, .{ .iterate = true });
        defer iterable.close(io);
        var iterator = iterable.iterate();
        while (try iterator.next(io)) |entry| {
            const temp = store_path.NamespaceTempName.parse(entry.name) catch continue;
            if (temp.kind == kind and temp.review_id.eql(self.binding.review_id) and
                !std.mem.eql(u8, entry.name, exception)) return error.UnexpectedOwnedTemp;
        }
    }
};

fn writePrivate(io: std.Io, directory: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    try directory.writeFile(io, .{
        .sub_path = name,
        .data = bytes,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
}
