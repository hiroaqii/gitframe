//! Repository asynchronous read ownership and worker terminals.
//!
//! Requests own every path and root capability captured for background work.
//! Task factories keep the App message type generic so this module never
//! imports page state, the coordinator, or the concrete root message.

const std = @import("std");
const chasen = @import("chasen");
const actions = @import("../../actions.zig");
const content_fingerprint = @import("../../../content_fingerprint.zig");
const page = @import("../../page.zig");
const git_backend = @import("../../../git/backend.zig");
const git_branch_status = @import("../../../git/branch_status.zig");
const process_runner = @import("../../../process/runner.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const selected_document = @import("../../../repository/document.zig");
const source_document = @import("../../../repository/source.zig");
const repository_change_map = @import("../../../repository/change_map.zig");
const repository_change_index = @import("../../../repository/change_index.zig");
const manifest = @import("../../../repository/manifest.zig");
const repository_tree = @import("../../../repository/tree.zig");
const source_syntax = @import("../../../syntax/source.zig");
const source_syntax_runtime = @import("../../../syntax/source_runtime.zig");
const repository_branch = @import("branch.zig");

pub const Bundle = struct {
    document: manifest.Document,
    tree: repository_tree.Tree,
    /// Present only when the optional status snapshot parsed successfully.
    /// The raw fingerprint is independent from the manifest fingerprint so a
    /// status-only refresh never invalidates the selected source document.
    status_fingerprint: ?content_fingerprint.Fingerprint = null,
    status_available: bool = false,

    pub fn deinit(self: *Bundle, allocator: std.mem.Allocator) void {
        self.tree.deinit(allocator);
        self.document.deinit(allocator);
        self.* = undefined;
    }
};

pub const StatusUpdate = union(enum) {
    loaded: repository_change_index.Index,
    unavailable,

    pub fn deinit(self: *StatusUpdate, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .loaded => |*index| index.deinit(allocator),
            .unavailable => {},
        }
        self.* = undefined;
    }
};

pub const TaskResult = union(enum) {
    unchanged: content_fingerprint.Fingerprint,
    status_changed: StatusUpdate,
    loaded: Bundle,
    failed_static: []const u8,

    pub fn deinit(self: *TaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .unchanged, .failed_static => {},
            .status_changed => |*update| update.deinit(allocator),
            .loaded => |*bundle| bundle.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ManifestFinished = struct {
    identity: page.RequestIdentity,
    root_identity: root_capability.Identity,
    generation: u64,
    result: TaskResult,

    pub fn deinit(self: *ManifestFinished, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const SyntaxResult = union(enum) {
    loaded: source_syntax.SourceSpans,
    unavailable,

    pub fn deinit(self: *SyntaxResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .loaded => |*spans| spans.deinit(allocator),
            .unavailable => {},
        }
        self.* = undefined;
    }
};

pub const SyntaxFinished = struct {
    identity: page.RequestIdentity,
    root_identity: root_capability.Identity,
    generation: u64,
    manifest_revision: u64,
    source_revision: u64,
    path: []u8,
    fingerprint: content_fingerprint.Fingerprint,
    result: SyntaxResult,

    pub fn deinit(self: *SyntaxFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const ChangeMapResult = union(enum) {
    loaded: repository_change_map.Map,
    unavailable,

    pub fn deinit(self: *ChangeMapResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .loaded => |*map| map.deinit(allocator),
            .unavailable => {},
        }
        self.* = undefined;
    }
};

pub const ChangeMapFinished = struct {
    identity: page.RequestIdentity,
    root_identity: root_capability.Identity,
    generation: u64,
    manifest_revision: u64,
    source_revision: u64,
    path: []u8,
    fingerprint: content_fingerprint.Fingerprint,
    content_line_count: usize,
    result: ChangeMapResult,

    pub fn deinit(self: *ChangeMapFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const DocumentValue = union(enum) {
    source: source_document.Document,
    inert: selected_document.Value,

    pub fn fromLoaded(allocator: std.mem.Allocator, loaded: *selected_document.Value) DocumentValue {
        return switch (loaded.*) {
            .text => |text| blk: {
                const source = source_document.Document.initOwned(allocator, text.bytes, text.fingerprint) catch {
                    allocator.free(text.bytes);
                    loaded.* = .unreadable;
                    break :blk .{ .inert = .unreadable };
                };
                loaded.* = .unreadable;
                break :blk .{ .source = source };
            },
            else => blk: {
                const inert = loaded.*;
                loaded.* = .unreadable;
                break :blk .{ .inert = inert };
            },
        };
    }

    pub fn deinit(self: *DocumentValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .source => |*source| source.deinit(allocator),
            .inert => |*inert| inert.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// A page-model allocation failure converts proved text to `unreadable`; that
/// failed conversion must not retain the source snapshot's metadata. Every
/// other metadata admission decision remains owned by the page-neutral loader
/// instead of duplicating its stable-classification list here.
fn metadataAfterDocumentConversion(
    value: *const DocumentValue,
    metadata: ?selected_document.StableMetadata,
) ?selected_document.StableMetadata {
    return switch (value.*) {
        .source => metadata,
        .inert => |inert| switch (inert) {
            .unreadable => null,
            else => metadata,
        },
    };
}

test "repository document conversion keeps proved metadata except on unreadable fallback" {
    const metadata: selected_document.StableMetadata = .{
        .modified_at = .{ .nanoseconds = 42 },
    };
    const binary: DocumentValue = .{ .inert = .binary };
    try std.testing.expectEqual(
        metadata.modified_at.nanoseconds,
        metadataAfterDocumentConversion(&binary, metadata).?.modified_at.nanoseconds,
    );
    const unreadable: DocumentValue = .{ .inert = .unreadable };
    try std.testing.expect(metadataAfterDocumentConversion(&unreadable, metadata) == null);
}

pub const DocumentFinished = struct {
    identity: page.RequestIdentity,
    root_identity: root_capability.Identity,
    generation: u64,
    manifest_revision: u64,
    path: []u8,
    value: DocumentValue,
    metadata: ?selected_document.StableMetadata = null,

    pub fn deinit(self: *DocumentFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub fn ManifestTask(comptime AppMsg: type) type {
    return struct {
        request: Request,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runManifestLoadChecked(
                task.request.root_path,
                task.request.root,
                task.request.expected_fingerprint,
                task.request.expected_status_fingerprint,
                allocator,
                io,
            ));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, .{ .failed_static = actions.taskFailureMessage(failure) });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.request.deinit(allocator);
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: TaskResult) AppMsg {
            defer allocator.destroy(task);
            defer task.request.deinit(allocator);
            const finished = ManifestFinished{
                .identity = task.request.identity,
                .root_identity = task.request.root.identity,
                .generation = task.request.generation,
                .result = result,
            };
            return .{ .repository = .{ .manifest_finished = finished } };
        }
    };
}

/// Repository branch task. The prepared request owns both forms of root
/// evidence: `root_path` is checked immediately around the read, while the
/// duplicated descriptor is the only cwd authority passed to Git.
pub fn BranchTask(comptime AppMsg: type) type {
    return struct {
        request: repository_branch.Request,
        /// Borrowed from process initialization. App and Chasen keep this map
        /// alive until every started task reaches `run` or `failed` cleanup.
        env_map: ?*const std.process.Environ.Map,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            return task.finish(allocator, runRepositoryBranchLoadChecked(
                task.request.root_path,
                task.request.root,
                task.env_map,
                allocator,
                io,
            ));
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            // Branch keeps its typed failure vocabulary; the shared
            // failure-string helper intentionally does not apply here.
            return task.finish(allocator, .{ .failed = switch (failure) {
                .start_failed => .start_failed,
                .runtime_abandoned => .runtime_abandoned,
            } });
        }

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.request.deinit(allocator);
            allocator.destroy(task);
        }

        /// Terminal epilogue shared by run and failed; owned-field release,
        /// moves, and destroy live only here.
        fn finish(task: *@This(), allocator: std.mem.Allocator, result: repository_branch.Result) AppMsg {
            defer allocator.destroy(task);
            defer task.request.deinit(allocator);
            const finished = repository_branch.Finished{
                .identity = task.request.identity,
                .root_identity = task.request.root.identity,
                .generation = task.request.generation,
                .result = result,
            };
            return .{ .repository = .{ .branch_finished = finished } };
        }
    };
}

const RepositoryBranchReadFn = *const fn (
    context: ?*anyopaque,
    cwd: std.Io.Dir,
    env_map: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    io: std.Io,
) repository_branch.Result;

fn runRepositoryBranchLoadChecked(
    root_path: []const u8,
    root: root_capability.RootCapability,
    env_map: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    io: std.Io,
) repository_branch.Result {
    return runRepositoryBranchLoadCheckedWithReader(
        root_path,
        root,
        env_map,
        allocator,
        io,
        null,
        readRepositoryBranchStatus,
    );
}

/// The private reader seam exists so replacement tests can deterministically
/// move the canonical path after the descriptor read but before the post-check.
/// Production always selects `readRepositoryBranchStatus`.
fn runRepositoryBranchLoadCheckedWithReader(
    root_path: []const u8,
    root: root_capability.RootCapability,
    env_map: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    io: std.Io,
    reader_context: ?*anyopaque,
    reader: RepositoryBranchReadFn,
) repository_branch.Result {
    if (!root_capability.pathMatches(root_path, root.identity)) {
        return .{ .failed = .root_changed };
    }
    var result = reader(reader_context, root.dir(), env_map, allocator, io);
    if (!root_capability.pathMatches(root_path, root.identity)) {
        // A successful backend result may own a complete arena. Close it here
        // before replacing the payload with the path-membership terminal.
        result.deinit();
        return .{ .failed = .root_changed };
    }
    return result;
}

fn readRepositoryBranchStatus(
    _: ?*anyopaque,
    cwd: std.Io.Dir,
    env_map: ?*const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    io: std.Io,
) repository_branch.Result {
    const raw = git_backend.LocalCommandBackend.loadBranchStatus(allocator, io, .{
        .cwd = .{ .dir = cwd },
        .parent_env = env_map,
    }) catch return .{ .failed = .load_failed };
    return switch (raw) {
        .ok => |bundle| .{ .loaded = bundle },
        .failed => |message| blk: {
            allocator.free(message);
            break :blk .{ .failed = .load_failed };
        },
        .failed_static => .{ .failed = .load_failed },
    };
}

fn runManifestLoadChecked(
    root_path: []const u8,
    root: root_capability.RootCapability,
    expected_fingerprint: ?content_fingerprint.Fingerprint,
    expected_status_fingerprint: ?content_fingerprint.Fingerprint,
    allocator: std.mem.Allocator,
    io: std.Io,
) TaskResult {
    if (!root_capability.pathMatches(root_path, root.identity)) return .{ .failed_static = "Repository root changed" };
    var result = runManifestLoad(root.dir(), expected_fingerprint, expected_status_fingerprint, allocator, io);
    if (!root_capability.pathMatches(root_path, root.identity)) {
        result.deinit(allocator);
        return .{ .failed_static = "Repository root changed" };
    }
    return result;
}

/// run/failed intentionally stay separate terminals (no shared `finish`):
/// the failure path returns an inert unreadable body, not a failure-string
/// variant of the success result.
pub fn DocumentTask(comptime AppMsg: type) type {
    return struct {
        request: DocumentRequest,

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.request.deinit(allocator);
            allocator.destroy(task);
        }

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.request.deinit(allocator);
            var snapshot = selected_document.load(task.request.root, task.request.path, allocator, io);
            defer snapshot.deinit(allocator);
            const value = DocumentValue.fromLoaded(allocator, &snapshot.value);
            const finished = DocumentFinished{
                .identity = task.request.identity,
                .root_identity = task.request.root.identity,
                .generation = task.request.generation,
                .manifest_revision = task.request.manifest_revision,
                .path = task.request.path,
                .value = value,
                .metadata = metadataAfterDocumentConversion(&value, snapshot.metadata),
            };
            snapshot.metadata = null;
            task.request.path = &.{};
            return .{ .repository = .{ .document_finished = finished } };
        }

        pub fn failed(ctx_ptr: *anyopaque, _: chasen.TaskFailure, allocator: std.mem.Allocator) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.request.deinit(allocator);
            const finished = DocumentFinished{
                .identity = task.request.identity,
                .root_identity = task.request.root.identity,
                .generation = task.request.generation,
                .manifest_revision = task.request.manifest_revision,
                .path = task.request.path,
                .value = .{ .inert = .unreadable },
            };
            task.request.path = &.{};
            return .{ .repository = .{ .document_finished = finished } };
        }
    };
}

/// run/failed intentionally stay separate terminals (no shared `finish`):
/// the failure path returns `.unavailable` with the expected fingerprint,
/// while success reports the measured one.
pub fn SyntaxTask(comptime AppMsg: type) type {
    return struct {
        request: SyntaxRequest,

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.request.deinit(allocator);
            allocator.destroy(task);
        }

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.request.deinit(allocator);
            // Re-read through an independently owned root/path instead of
            // borrowing DisplayedDocument across threads. The extra bounded
            // read keeps plain-source acceptance immediate and avoids shared or
            // refcounted mutable lifetime between page state and the worker.
            var snapshot = selected_document.load(task.request.root, task.request.path, allocator, io);
            defer snapshot.deinit(allocator);
            var fingerprint = task.request.expected_fingerprint;
            var result: SyntaxResult = .unavailable;
            switch (snapshot.value) {
                .text => |text| {
                    var document: ?source_document.Document = source_document.Document.initOwned(allocator, text.bytes, text.fingerprint) catch null;
                    if (document) |*source| {
                        snapshot.value = .unreadable;
                        defer source.deinit(allocator);
                        fingerprint = source.fingerprint;
                        const spans: ?source_syntax.SourceSpans = source_syntax_runtime.buildSourceSpans(allocator, io, source, task.request.path) catch null;
                        if (spans) |owned| result = .{ .loaded = owned };
                    }
                },
                else => {},
            }
            const finished = SyntaxFinished{
                .identity = task.request.identity,
                .root_identity = task.request.root.identity,
                .generation = task.request.generation,
                .manifest_revision = task.request.manifest_revision,
                .source_revision = task.request.source_revision,
                .path = task.request.path,
                .fingerprint = fingerprint,
                .result = result,
            };
            task.request.path = &.{};
            return .{ .repository = .{ .syntax_finished = finished } };
        }

        pub fn failed(ctx_ptr: *anyopaque, _: chasen.TaskFailure, allocator: std.mem.Allocator) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.request.deinit(allocator);
            const finished = SyntaxFinished{
                .identity = task.request.identity,
                .root_identity = task.request.root.identity,
                .generation = task.request.generation,
                .manifest_revision = task.request.manifest_revision,
                .source_revision = task.request.source_revision,
                .path = task.request.path,
                .fingerprint = task.request.expected_fingerprint,
                .result = .unavailable,
            };
            task.request.path = &.{};
            return .{ .repository = .{ .syntax_finished = finished } };
        }
    };
}

/// run/failed intentionally stay separate terminals (no shared `finish`):
/// the failure path returns `.unavailable` with the expected fingerprint and
/// line count, while success reports measured values.
pub fn ChangeMapTask(comptime AppMsg: type) type {
    return struct {
        request: ChangeMapRequest,

        /// Spawn-failure counterpart of the terminal epilogue: releases the
        /// task-owned payload without producing a Msg.
        pub fn destroy(task: *@This(), allocator: std.mem.Allocator) void {
            task.request.deinit(allocator);
            allocator.destroy(task);
        }

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.request.deinit(allocator);

            var fingerprint = task.request.expected_fingerprint;
            var content_line_count = task.request.expected_content_line_count;
            var result: ChangeMapResult = .unavailable;
            var snapshot = selected_document.load(task.request.root, task.request.path, allocator, io);
            defer snapshot.deinit(allocator);
            var value = DocumentValue.fromLoaded(allocator, &snapshot.value);
            defer value.deinit(allocator);
            switch (value) {
                .source => |*source| {
                    fingerprint = source.fingerprint;
                    content_line_count = source.contentLineCount();
                    if (task.request.expected_fingerprint.eql(fingerprint) and
                        task.request.expected_content_line_count == content_line_count)
                    {
                        result = loadChangeMap(
                            allocator,
                            io,
                            task.request.root.dir(),
                            task.request.path,
                            source,
                            task.request.temp_base_path,
                        );
                    }
                },
                .inert => {},
            }

            const finished = ChangeMapFinished{
                .identity = task.request.identity,
                .root_identity = task.request.root.identity,
                .generation = task.request.generation,
                .manifest_revision = task.request.manifest_revision,
                .source_revision = task.request.source_revision,
                .path = task.request.path,
                .fingerprint = fingerprint,
                .content_line_count = content_line_count,
                .result = result,
            };
            task.request.path = &.{};
            return .{ .repository = .{ .change_map_finished = finished } };
        }

        pub fn failed(ctx_ptr: *anyopaque, _: chasen.TaskFailure, allocator: std.mem.Allocator) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.request.deinit(allocator);
            const finished = ChangeMapFinished{
                .identity = task.request.identity,
                .root_identity = task.request.root.identity,
                .generation = task.request.generation,
                .manifest_revision = task.request.manifest_revision,
                .source_revision = task.request.source_revision,
                .path = task.request.path,
                .fingerprint = task.request.expected_fingerprint,
                .content_line_count = task.request.expected_content_line_count,
                .result = .unavailable,
            };
            task.request.path = &.{};
            return .{ .repository = .{ .change_map_finished = finished } };
        }
    };
}

fn loadChangeMap(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
    source: *const source_document.Document,
    temp_base_path: []const u8,
) ChangeMapResult {
    const loaded = git_backend.LocalCommandBackend.loadRepositoryFileChange(allocator, io, .{
        .cwd = cwd,
        .path = path,
        .source_bytes = source.bytes,
        .temp_base_path = temp_base_path,
    }) catch return .unavailable;
    defer loaded.deinit(allocator);
    const map = switch (loaded) {
        .all_added => repository_change_map.allAdded(allocator, source.contentLineCount()),
        .patch => |patch| repository_change_map.fromPatch(allocator, patch, source.contentLineCount()),
        .unchanged => repository_change_map.fromPatch(allocator, "", source.contentLineCount()),
        .failed_static => return .unavailable,
    } catch return .unavailable;
    return .{ .loaded = map };
}

pub fn runManifestLoad(
    cwd: std.Io.Dir,
    expected_fingerprint: ?content_fingerprint.Fingerprint,
    expected_status_fingerprint: ?content_fingerprint.Fingerprint,
    allocator: std.mem.Allocator,
    io: std.Io,
) TaskResult {
    const raw_manifest = git_backend.LocalCommandBackend.loadRepositoryManifest(allocator, io, .{ .cwd = cwd }) catch
        return .{ .failed_static = "Repository manifest could not be loaded" };
    const raw_status = git_backend.LocalCommandBackend.loadRepositoryFileStatus(allocator, io, .{ .cwd = cwd }) catch null;
    return buildManifestTaskResult(allocator, raw_manifest, raw_status, expected_fingerprint, expected_status_fingerprint);
}

/// Resolves the manifest/status result-owner matrix after both descriptor-safe
/// reads complete. Status is optional: any command or parser failure removes
/// decoration but cannot invalidate a usable manifest. A changed manifest
/// always reparses status, even when its raw fingerprint is unchanged, because
/// the path projection belongs to the new tree generation.
fn buildManifestTaskResult(
    allocator: std.mem.Allocator,
    raw_manifest: git_backend.RepositoryManifestLoadResult,
    raw_status: ?git_backend.RepositoryFileStatusLoadResult,
    expected_fingerprint: ?content_fingerprint.Fingerprint,
    expected_status_fingerprint: ?content_fingerprint.Fingerprint,
) TaskResult {
    const status_bytes: ?[]u8 = if (raw_status) |status| switch (status) {
        .ok => |bytes| bytes,
        .failed_static => null,
    } else null;

    switch (raw_manifest) {
        .ok => |manifest_bytes| {
            const fingerprint = content_fingerprint.Fingerprint.init(manifest_bytes);
            const manifest_same = if (expected_fingerprint) |expected| expected.eql(fingerprint) else false;
            if (status_bytes) |bytes| {
                const status_fingerprint = content_fingerprint.Fingerprint.init(bytes);
                const status_same = if (expected_status_fingerprint) |expected| expected.eql(status_fingerprint) else false;
                if (manifest_same and status_same) {
                    allocator.free(bytes);
                    allocator.free(manifest_bytes);
                    return .{ .unchanged = fingerprint };
                }
                if (manifest_same) {
                    allocator.free(manifest_bytes);
                    const index = repository_change_index.parseOwned(allocator, bytes) catch
                        return .{ .status_changed = .unavailable };
                    return .{ .status_changed = .{ .loaded = index } };
                }

                var document = manifest.parseOwned(allocator, manifest_bytes) catch {
                    allocator.free(bytes);
                    return .{ .failed_static = "Repository manifest could not be parsed" };
                };
                const tree = repository_tree.Tree.build(allocator, &document) catch {
                    allocator.free(bytes);
                    document.deinit(allocator);
                    return .{ .failed_static = "Repository tree could not be built" };
                };
                var bundle = Bundle{ .document = document, .tree = tree };
                var index = repository_change_index.parseOwned(allocator, bytes) catch return .{ .loaded = bundle };
                defer index.deinit(allocator);
                _ = bundle.tree.applyChangeIndex(&index);
                bundle.status_fingerprint = index.fingerprint;
                bundle.status_available = true;
                return .{ .loaded = bundle };
            }

            if (manifest_same) {
                allocator.free(manifest_bytes);
                return .{ .status_changed = .unavailable };
            }
            var document = manifest.parseOwned(allocator, manifest_bytes) catch
                return .{ .failed_static = "Repository manifest could not be parsed" };
            const tree = repository_tree.Tree.build(allocator, &document) catch {
                document.deinit(allocator);
                return .{ .failed_static = "Repository tree could not be built" };
            };
            return .{ .loaded = .{ .document = document, .tree = tree } };
        },
        .failed => |message| {
            if (status_bytes) |bytes| allocator.free(bytes);
            allocator.free(message);
            return .{ .failed_static = "Repository manifest could not be loaded" };
        },
        .failed_static => |message| {
            if (status_bytes) |bytes| allocator.free(bytes);
            return .{ .failed_static = message };
        },
    }
}

pub const Request = struct {
    identity: page.RequestIdentity,
    generation: u64,
    root_path: []u8,
    root: root_capability.RootCapability,
    expected_fingerprint: ?content_fingerprint.Fingerprint,
    expected_status_fingerprint: ?content_fingerprint.Fingerprint = null,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.root_path);
        self.root.deinit();
        self.* = undefined;
    }
};

pub const DocumentRequest = struct {
    identity: page.RequestIdentity,
    generation: u64,
    manifest_revision: u64,
    path: []u8,
    root: root_capability.RootCapability,

    pub fn deinit(self: *DocumentRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.root.deinit();
        self.* = undefined;
    }
};

pub const SyntaxRequest = struct {
    identity: page.RequestIdentity,
    generation: u64,
    manifest_revision: u64,
    source_revision: u64,
    expected_fingerprint: content_fingerprint.Fingerprint,
    path: []u8,
    root: root_capability.RootCapability,

    pub fn deinit(self: *SyntaxRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.root.deinit();
        self.* = undefined;
    }
};

pub const ChangeMapRequest = struct {
    identity: page.RequestIdentity,
    generation: u64,
    manifest_revision: u64,
    source_revision: u64,
    expected_fingerprint: content_fingerprint.Fingerprint,
    expected_content_line_count: usize,
    path: []u8,
    root: root_capability.RootCapability,
    temp_base_path: []u8,

    pub fn deinit(self: *ChangeMapRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.root.deinit();
        allocator.free(self.temp_base_path);
        self.* = undefined;
    }
};

fn manifestResultForTest(bytes: []const u8) !git_backend.RepositoryManifestLoadResult {
    return .{ .ok = try std.testing.allocator.dupe(u8, bytes) };
}

fn statusResultForTest(bytes: []const u8) !git_backend.RepositoryFileStatusLoadResult {
    return .{ .ok = try std.testing.allocator.dupe(u8, bytes) };
}

test "repository manifest task result matrix keeps manifest and status identities separate" {
    const allocator = std.testing.allocator;
    const old_manifest = "a.zig\x00";
    const new_manifest = "a.zig\x00new.zig\x00";
    const old_status = " M a.zig\x00";
    const new_status = "?? new.zig\x00";
    const old_manifest_fingerprint = content_fingerprint.Fingerprint.init(old_manifest);
    const old_status_fingerprint = content_fingerprint.Fingerprint.init(old_status);

    var unchanged = buildManifestTaskResult(
        allocator,
        try manifestResultForTest(old_manifest),
        try statusResultForTest(old_status),
        old_manifest_fingerprint,
        old_status_fingerprint,
    );
    defer unchanged.deinit(allocator);
    try std.testing.expect(unchanged == .unchanged);

    var status_only = buildManifestTaskResult(
        allocator,
        try manifestResultForTest(old_manifest),
        try statusResultForTest(new_status),
        old_manifest_fingerprint,
        old_status_fingerprint,
    );
    defer status_only.deinit(allocator);
    try std.testing.expectEqual(repository_change_index.Kind.added, status_only.status_changed.loaded.kindForPath("new.zig").?);

    var status_unavailable = buildManifestTaskResult(
        allocator,
        try manifestResultForTest(old_manifest),
        git_backend.RepositoryFileStatusLoadResult{ .failed_static = "optional failure" },
        old_manifest_fingerprint,
        old_status_fingerprint,
    );
    defer status_unavailable.deinit(allocator);
    try std.testing.expect(status_unavailable.status_changed == .unavailable);

    // A new tree generation must reproject the unchanged raw status instead of
    // reusing an Index whose path membership belonged to the previous tree.
    var manifest_only = buildManifestTaskResult(
        allocator,
        try manifestResultForTest(new_manifest),
        try statusResultForTest(old_status),
        old_manifest_fingerprint,
        old_status_fingerprint,
    );
    defer manifest_only.deinit(allocator);
    try std.testing.expect(manifest_only == .loaded);
    try std.testing.expect(manifest_only.loaded.status_available);
    try std.testing.expectEqual(repository_change_index.Kind.modified, manifest_only.loaded.tree.nodes[0].file_change.?);
    try std.testing.expect(manifest_only.loaded.tree.nodes[1].file_change == null);

    var both_changed = buildManifestTaskResult(
        allocator,
        try manifestResultForTest(new_manifest),
        try statusResultForTest(new_status),
        old_manifest_fingerprint,
        old_status_fingerprint,
    );
    defer both_changed.deinit(allocator);
    try std.testing.expectEqual(repository_change_index.Kind.added, both_changed.loaded.tree.nodes[1].file_change.?);

    var malformed_optional = buildManifestTaskResult(
        allocator,
        try manifestResultForTest(new_manifest),
        try statusResultForTest(" M unterminated"),
        old_manifest_fingerprint,
        old_status_fingerprint,
    );
    defer malformed_optional.deinit(allocator);
    try std.testing.expect(malformed_optional == .loaded);
    try std.testing.expect(!malformed_optional.loaded.status_available);
    for (malformed_optional.loaded.tree.nodes) |node| try std.testing.expect(node.file_change == null);

    var manifest_failed = buildManifestTaskResult(
        allocator,
        git_backend.RepositoryManifestLoadResult{ .failed = try allocator.dupe(u8, "private diagnostic") },
        try statusResultForTest(new_status),
        old_manifest_fingerprint,
        old_status_fingerprint,
    );
    defer manifest_failed.deinit(allocator);
    try std.testing.expect(manifest_failed == .failed_static);
}

const ManifestStatusAllocationFixture = struct {
    fn exercise(allocator: std.mem.Allocator) !void {
        const manifest_bytes = try allocator.dupe(u8, "a.zig\x00clean.zig\x00");
        var manifest_owned = true;
        errdefer if (manifest_owned) allocator.free(manifest_bytes);
        const status_bytes = try allocator.dupe(u8, " M a.zig\x00");
        manifest_owned = false;
        var result = buildManifestTaskResult(
            allocator,
            .{ .ok = manifest_bytes },
            .{ .ok = status_bytes },
            content_fingerprint.Fingerprint.init("old.zig\x00"),
            content_fingerprint.Fingerprint.init("?? old.zig\x00"),
        );
        defer result.deinit(allocator);
        switch (result) {
            .loaded => |bundle| if (!bundle.status_available) return error.OutOfMemory,
            else => return error.OutOfMemory,
        }
    }
};

test "repository manifest status matrix releases every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ManifestStatusAllocationFixture.exercise, .{});
}

fn runTaskTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    const result = try process_runner.runCaptured(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer result.deinit(std.testing.allocator);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.RepositoryTestGitFailed;
}

const TaskTestRepositoryMsg = union(enum) {
    manifest_finished: ManifestFinished,
    branch_finished: repository_branch.Finished,
    document_finished: DocumentFinished,
    syntax_finished: SyntaxFinished,
    change_map_finished: ChangeMapFinished,

    fn deinitUndelivered(self: *TaskTestRepositoryMsg, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .manifest_finished => |*finished| finished.deinit(allocator),
            .branch_finished => |*finished| finished.deinit(),
            .document_finished => |*finished| finished.deinit(allocator),
            .syntax_finished => |*finished| finished.deinit(allocator),
            .change_map_finished => |*finished| finished.deinit(allocator),
        }
        self.* = undefined;
    }
};

const TaskTestMsg = union(enum) { repository: TaskTestRepositoryMsg };

const TaskTestRoot = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    capability: root_capability.RootCapability,

    fn init() !TaskTestRoot {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        errdefer std.testing.allocator.free(path);
        return .{
            .tmp = tmp,
            .path = path,
            .capability = try root_capability.RootCapability.openCanonical(path),
        };
    }

    fn deinit(self: *TaskTestRoot) void {
        self.capability.deinit();
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn initializeBranchTaskRepository(root: *TaskTestRoot) !void {
    const io = std.testing.io;
    try runTaskTestGit(io, root.tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try root.tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\n" });
    try runTaskTestGit(io, root.tmp.dir, &.{ "git", "add", "tracked.txt" });
    try runTaskTestGit(io, root.tmp.dir, &.{
        "git",
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "-m",
        "base",
    });
}

test "Repository branch task reads through its descriptor and posts an owned completion" {
    const allocator = std.testing.allocator;
    var root = try TaskTestRoot.init();
    defer root.deinit();
    try initializeBranchTaskRepository(&root);

    const Branch = BranchTask(TaskTestMsg);
    const task = try allocator.create(Branch);
    task.* = .{
        .request = .{
            .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
            .generation = 5,
            .root_path = try allocator.dupe(u8, root.path),
            .root = try root.capability.duplicate(),
        },
        .env_map = null,
    };
    var message = Branch.run(task, allocator, std.testing.io);
    defer message.repository.deinitUndelivered(allocator);
    switch (message.repository) {
        .branch_finished => |finished| {
            try std.testing.expect(root.capability.identity.eql(finished.root_identity));
            try std.testing.expect(finished.result == .loaded);
            try std.testing.expectEqualStrings("main", finished.result.loaded.status.branchName().?);
        },
        else => return error.ExpectedBranchCompletion,
    }
}

test "Repository branch task failure callback preserves typed runtime ownership" {
    const allocator = std.testing.allocator;
    var root = try TaskTestRoot.init();
    defer root.deinit();

    const Branch = BranchTask(TaskTestMsg);
    const task = try allocator.create(Branch);
    task.* = .{
        .request = .{
            .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
            .generation = 5,
            .root_path = try allocator.dupe(u8, root.path),
            .root = try root.capability.duplicate(),
        },
        .env_map = null,
    };
    var message = Branch.failed(task, .runtime_abandoned, allocator);
    defer message.repository.deinitUndelivered(allocator);
    switch (message.repository) {
        .branch_finished => |finished| {
            try std.testing.expect(root.capability.identity.eql(finished.root_identity));
            try std.testing.expectEqual(repository_branch.Failure.runtime_abandoned, finished.result.failed);
        },
        else => return error.ExpectedBranchCompletion,
    }
}

test "repository tasks derive completion root identity from their descriptor" {
    var root_a = try TaskTestRoot.init();
    defer root_a.deinit();
    var root_b = try TaskTestRoot.init();
    defer root_b.deinit();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const expected_identity = root_b.capability.identity;

    const Manifest = ManifestTask(TaskTestMsg);
    const manifest_task = try allocator.create(Manifest);
    manifest_task.* = .{
        .request = .{
            .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
            .generation = 5,
            .root_path = try allocator.dupe(u8, root_a.path),
            .root = try root_b.capability.duplicate(),
            .expected_fingerprint = null,
        },
    };
    var manifest_message = Manifest.run(manifest_task, allocator, io);
    defer manifest_message.repository.deinitUndelivered(allocator);
    switch (manifest_message.repository) {
        .manifest_finished => |finished| {
            try std.testing.expect(expected_identity.eql(finished.root_identity));
            try std.testing.expect(finished.result == .failed_static);
        },
        else => return error.ExpectedManifestCompletion,
    }

    const Document = DocumentTask(TaskTestMsg);
    const document_task = try allocator.create(Document);
    document_task.* = .{
        .request = .{
            .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
            .generation = 6,
            .manifest_revision = 7,
            .path = try allocator.dupe(u8, "missing.txt"),
            .root = try root_b.capability.duplicate(),
        },
    };
    var document_message = Document.run(document_task, allocator, io);
    defer document_message.repository.deinitUndelivered(allocator);
    switch (document_message.repository) {
        .document_finished => |finished| try std.testing.expect(expected_identity.eql(finished.root_identity)),
        else => return error.ExpectedDocumentCompletion,
    }

    const source_bytes = "const value: usize = 42;\n";
    try root_b.tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = source_bytes });
    const Syntax = SyntaxTask(TaskTestMsg);
    const syntax_task = try allocator.create(Syntax);
    syntax_task.* = .{
        .request = .{
            .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
            .generation = 8,
            .manifest_revision = 9,
            .source_revision = 10,
            .expected_fingerprint = .init(source_bytes),
            .path = try allocator.dupe(u8, "main.zig"),
            .root = try root_b.capability.duplicate(),
        },
    };
    var syntax_message = Syntax.run(syntax_task, allocator, io);
    defer syntax_message.repository.deinitUndelivered(allocator);
    switch (syntax_message.repository) {
        .syntax_finished => |finished| {
            try std.testing.expect(expected_identity.eql(finished.root_identity));
            try std.testing.expect(finished.fingerprint.eql(.init(source_bytes)));
            try std.testing.expectEqualStrings("main.zig", finished.path);
            try std.testing.expect(finished.result == .loaded);
        },
        else => return error.ExpectedSyntaxCompletion,
    }

    const ChangeMap = ChangeMapTask(TaskTestMsg);
    const change_map_task = try allocator.create(ChangeMap);
    change_map_task.* = .{
        .request = .{
            .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
            .generation = 11,
            .manifest_revision = 12,
            .source_revision = 13,
            .expected_fingerprint = .init(source_bytes),
            .expected_content_line_count = 1,
            .path = try allocator.dupe(u8, "main.zig"),
            .root = try root_b.capability.duplicate(),
            .temp_base_path = try allocator.dupe(u8, "/tmp"),
        },
    };
    var change_map_message = ChangeMap.run(change_map_task, allocator, io);
    defer change_map_message.repository.deinitUndelivered(allocator);
    switch (change_map_message.repository) {
        .change_map_finished => |finished| {
            try std.testing.expect(expected_identity.eql(finished.root_identity));
            try std.testing.expect(finished.fingerprint.eql(.init(source_bytes)));
            try std.testing.expectEqualStrings("main.zig", finished.path);
        },
        else => return error.ExpectedChangeMapCompletion,
    }
}

test "repository document task builds the bounded source model before delivery" {
    var root = try TaskTestRoot.init();
    defer root.deinit();
    try root.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.zig", .data = "first\r\nsecond\n" });
    const expected = try root.tmp.dir.statFile(std.testing.io, "source.zig", .{});
    const allocator = std.testing.allocator;
    const Document = DocumentTask(TaskTestMsg);
    const task = try allocator.create(Document);
    task.* = .{
        .request = .{
            .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
            .generation = 5,
            .manifest_revision = 6,
            .path = try allocator.dupe(u8, "source.zig"),
            .root = try root.capability.duplicate(),
        },
    };
    var message = Document.run(task, allocator, std.testing.io);
    defer message.repository.deinitUndelivered(allocator);
    switch (message.repository) {
        .document_finished => |finished| switch (finished.value) {
            .source => |source| {
                try std.testing.expectEqual(@as(usize, 2), source.rowCount());
                try std.testing.expectEqualStrings("first", source.lineBody(0).?);
                try std.testing.expectEqualStrings("second", source.lineBody(1).?);
                try std.testing.expectEqual(expected.mtime.nanoseconds, finished.metadata.?.modified_at.nanoseconds);
            },
            .inert => return error.ExpectedSource,
        },
        else => return error.ExpectedDocumentCompletion,
    }
}

const BranchReplacementReader = struct {
    tmp: *std.testing.TmpDir,
    original: []const u8,
    parked: []const u8,
    replacement: []const u8,

    fn readThenReplace(
        context: ?*anyopaque,
        cwd: std.Io.Dir,
        env_map: ?*const std.process.Environ.Map,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) repository_branch.Result {
        var result = readRepositoryBranchStatus(null, cwd, env_map, allocator, io);
        if (result != .loaded) return result;
        const self: *BranchReplacementReader = @ptrCast(@alignCast(context.?));
        self.tmp.dir.rename(self.original, self.tmp.dir, self.parked, io) catch {
            result.deinit();
            return .{ .failed = .load_failed };
        };
        self.tmp.dir.rename(self.replacement, self.tmp.dir, self.original, io) catch {
            result.deinit();
            return .{ .failed = .load_failed };
        };
        return result;
    }
};

fn expectRepositoryBranchPostCheckRejectsReplacement(ancestor: bool) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = if (ancestor) "base" else "repo";
    const parked = if (ancestor) "old-base" else "old-repo";
    const replacement = "replacement";
    const relative_root = if (ancestor) "base/repo" else "repo";
    const replacement_root = if (ancestor) "replacement/repo" else replacement;
    if (ancestor) {
        try tmp.dir.createDirPath(io, relative_root);
        try tmp.dir.createDirPath(io, replacement_root);
    } else {
        try tmp.dir.createDir(io, relative_root, .default_dir);
        try tmp.dir.createDir(io, replacement_root, .default_dir);
    }
    {
        var work = try tmp.dir.openDir(io, relative_root, .{});
        defer work.close(io);
        try runTaskTestGit(io, work, &.{ "git", "init", "--initial-branch=main" });
        try work.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\n" });
        try runTaskTestGit(io, work, &.{ "git", "add", "tracked.txt" });
        try runTaskTestGit(io, work, &.{
            "git",
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "-m",
            "base",
        });
    }
    const root_path = try tmp.dir.realPathFileAlloc(io, relative_root, allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();
    var reader = BranchReplacementReader{
        .tmp = &tmp,
        .original = original,
        .parked = parked,
        .replacement = replacement,
    };
    var result = runRepositoryBranchLoadCheckedWithReader(
        root_path,
        root,
        null,
        allocator,
        io,
        &reader,
        BranchReplacementReader.readThenReplace,
    );
    defer result.deinit();
    try std.testing.expectEqual(repository_branch.Failure.root_changed, result.failed);
}

test "Repository branch task post-check rejects final root replacement" {
    try expectRepositoryBranchPostCheckRejectsReplacement(false);
}

test "Repository branch task post-check rejects ancestor replacement" {
    try expectRepositoryBranchPostCheckRejectsReplacement(true);
}

test "repository manifest root liveness check rejects stable path replacement" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    try tmp.dir.createDir(io, "outside", .default_dir);
    const root_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();
    try tmp.dir.rename("repo", tmp.dir, "old-repo", io);
    try tmp.dir.symLink(io, "outside", "repo", .{ .is_directory = true });

    var result = runManifestLoadChecked(root_path, root, null, null, allocator, io);
    defer result.deinit(allocator);
    switch (result) {
        .failed_static => |message| try std.testing.expectEqualStrings("Repository root changed", message),
        else => return error.ExpectedRootChanged,
    }
}
