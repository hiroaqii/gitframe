const std = @import("std");
const chasen = @import("chasen");
const draw = @import("draw");
const theme = @import("theme");
const app_state = @import("../state.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const page = @import("../page.zig");
const git_backend = @import("../../git/backend.zig");
const process_runner = @import("../../process/runner.zig");
const root_capability = @import("../../repo/root_capability.zig");
const selected_document = @import("../../repository/document.zig");
const source_document = @import("../../repository/source.zig");
const repository_change_map = @import("../../repository/change_map.zig");
const repository_change_index = @import("../../repository/change_index.zig");
const manifest = @import("../../repository/manifest.zig");
const repository_tree = @import("../../repository/tree.zig");
const source_syntax = @import("../../syntax/source.zig");
const source_syntax_runtime = @import("../../syntax/source_runtime.zig");
const repository_input = @import("repository/input.zig");
const repository_model = @import("repository/model.zig");
const repository_navigation = @import("repository/navigation.zig");
const repository_view = @import("repository/view.zig");

pub const InputContext = repository_input.Context;

pub const LoadState = enum { idle, no_repository, loading, loaded, empty, failed };

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

pub const DisplayedDocument = struct {
    path: []u8,
    manifest_revision: u64,
    source_revision: u64 = 0,
    value: DocumentValue,
    syntax_spans: source_syntax.SourceSpans = .empty(),
    change_decoration: ChangeDecoration = .terminal_plain,

    pub fn deinit(self: *DisplayedDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.value.deinit(allocator);
        self.syntax_spans.deinit(allocator);
        self.change_decoration.deinit(allocator);
        self.* = undefined;
    }
};

/// Explicit async decoration state. `eligible` means the accepted source still
/// needs exactly one comparison; `terminal_plain` is a deliberate fail-closed
/// result, not an invitation to retry on every unrelated event.
pub const ChangeDecoration = union(enum) {
    eligible,
    resolved: repository_change_map.Map,
    terminal_plain,

    pub fn deinit(self: *ChangeDecoration, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .resolved => |*resolved| resolved.deinit(allocator),
            .eligible, .terminal_plain => {},
        }
        self.* = .terminal_plain;
    }

    pub fn map(self: *const ChangeDecoration) ?*const repository_change_map.Map {
        return switch (self.*) {
            .resolved => |*resolved| resolved,
            .eligible, .terminal_plain => null,
        };
    }

    pub fn isEligible(self: *const ChangeDecoration) bool {
        return switch (self.*) {
            .eligible => true,
            .resolved, .terminal_plain => false,
        };
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

pub const DocumentFinished = struct {
    identity: page.RequestIdentity,
    root_identity: root_capability.Identity,
    generation: u64,
    manifest_revision: u64,
    path: []u8,
    value: DocumentValue,

    pub fn deinit(self: *DocumentFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const Msg = union(enum) {
    manifest_finished: ManifestFinished,
    document_finished: DocumentFinished,
    syntax_finished: SyntaxFinished,
    change_map_finished: ChangeMapFinished,
    move_up,
    move_down,
    toggle_directory,
    page_up,
    page_down,
    scroll_left,
    scroll_right,
    mouse_row: usize,
    mouse_toggle_row: usize,
    mouse_source_row: usize,
    mouse_source_wheel_up,
    mouse_source_wheel_down,
    focus_tree,
    focus_source,
    toggle_focus,
    tree_first,
    tree_last,
    source_first,
    source_last,
    toggle_changed_filter,
    toggle_line_numbers,
    enter_source_search,
    cancel_source_search,
    submit_source_search,
    clear_source_search,
    next_source_match,
    previous_source_match,
    source_search_backspace,
    source_search_move_left,
    source_search_move_right,
    source_search_insert: u21,
    source_search_paste: []const u8,
    enter_file_search,
    cancel_file_search,
    submit_file_search,
    file_search_previous,
    file_search_next,
    file_search_backspace,
    file_search_insert: u21,
    file_search_paste: []const u8,
    wheel_up,
    wheel_down,

    pub fn deinitUndelivered(self: *Msg, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .manifest_finished => |*finished| finished.deinit(allocator),
            .document_finished => |*finished| finished.deinit(allocator),
            .syntax_finished => |*finished| finished.deinit(allocator),
            .change_map_finished => |*finished| finished.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

pub fn ManifestTask(comptime AppMsg: type) type {
    return struct {
        identity: page.RequestIdentity,
        generation: u64,
        root_path: []u8,
        root: root_capability.RootCapability,
        expected_fingerprint: ?content_fingerprint.Fingerprint,
        expected_status_fingerprint: ?content_fingerprint.Fingerprint = null,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer allocator.free(task.root_path);
            defer task.root.deinit();
            const result = runManifestLoadChecked(
                task.root_path,
                task.root,
                task.expected_fingerprint,
                task.expected_status_fingerprint,
                allocator,
                io,
            );
            const finished = ManifestFinished{
                .identity = task.identity,
                .root_identity = task.root.identity,
                .generation = task.generation,
                .result = result,
            };
            return .{ .repository = .{ .manifest_finished = finished } };
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer allocator.free(task.root_path);
            defer task.root.deinit();
            const finished = ManifestFinished{
                .identity = task.identity,
                .root_identity = task.root.identity,
                .generation = task.generation,
                .result = .{ .failed_static = switch (failure) {
                    .start_failed => |message| message,
                    .runtime_abandoned => "runtime shutting down",
                } },
            };
            return .{ .repository = .{ .manifest_finished = finished } };
        }
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

pub fn DocumentTask(comptime AppMsg: type) type {
    return struct {
        identity: page.RequestIdentity,
        generation: u64,
        manifest_revision: u64,
        path: []u8,
        root: root_capability.RootCapability,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.root.deinit();
            var loaded = selected_document.load(task.root, task.path, allocator, io);
            defer loaded.deinit(allocator);
            const finished = DocumentFinished{
                .identity = task.identity,
                .root_identity = task.root.identity,
                .generation = task.generation,
                .manifest_revision = task.manifest_revision,
                .path = task.path,
                .value = DocumentValue.fromLoaded(allocator, &loaded),
            };
            task.path = &.{};
            return .{ .repository = .{ .document_finished = finished } };
        }

        pub fn failed(ctx_ptr: *anyopaque, _: chasen.TaskFailure, allocator: std.mem.Allocator) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.root.deinit();
            const finished = DocumentFinished{
                .identity = task.identity,
                .root_identity = task.root.identity,
                .generation = task.generation,
                .manifest_revision = task.manifest_revision,
                .path = task.path,
                .value = .{ .inert = .unreadable },
            };
            task.path = &.{};
            return .{ .repository = .{ .document_finished = finished } };
        }
    };
}

pub fn SyntaxTask(comptime AppMsg: type) type {
    return struct {
        identity: page.RequestIdentity,
        generation: u64,
        manifest_revision: u64,
        source_revision: u64,
        expected_fingerprint: content_fingerprint.Fingerprint,
        path: []u8,
        root: root_capability.RootCapability,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.root.deinit();
            // Re-read through an independently owned root/path instead of
            // borrowing DisplayedDocument across threads. The extra bounded
            // read keeps plain-source acceptance immediate and avoids shared or
            // refcounted mutable lifetime between page state and the worker.
            var loaded = selected_document.load(task.root, task.path, allocator, io);
            defer loaded.deinit(allocator);
            var fingerprint = task.expected_fingerprint;
            var result: SyntaxResult = .unavailable;
            switch (loaded) {
                .text => |text| {
                    var document: ?source_document.Document = source_document.Document.initOwned(allocator, text.bytes, text.fingerprint) catch null;
                    if (document) |*source| {
                        loaded = .unreadable;
                        defer source.deinit(allocator);
                        fingerprint = source.fingerprint;
                        const spans: ?source_syntax.SourceSpans = source_syntax_runtime.buildSourceSpans(allocator, io, source, task.path) catch null;
                        if (spans) |owned| result = .{ .loaded = owned };
                    }
                },
                else => {},
            }
            const finished = SyntaxFinished{
                .identity = task.identity,
                .root_identity = task.root.identity,
                .generation = task.generation,
                .manifest_revision = task.manifest_revision,
                .source_revision = task.source_revision,
                .path = task.path,
                .fingerprint = fingerprint,
                .result = result,
            };
            task.path = &.{};
            return .{ .repository = .{ .syntax_finished = finished } };
        }

        pub fn failed(ctx_ptr: *anyopaque, _: chasen.TaskFailure, allocator: std.mem.Allocator) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.root.deinit();
            const finished = SyntaxFinished{
                .identity = task.identity,
                .root_identity = task.root.identity,
                .generation = task.generation,
                .manifest_revision = task.manifest_revision,
                .source_revision = task.source_revision,
                .path = task.path,
                .fingerprint = task.expected_fingerprint,
                .result = .unavailable,
            };
            task.path = &.{};
            return .{ .repository = .{ .syntax_finished = finished } };
        }
    };
}

pub fn ChangeMapTask(comptime AppMsg: type) type {
    return struct {
        identity: page.RequestIdentity,
        generation: u64,
        manifest_revision: u64,
        source_revision: u64,
        expected_fingerprint: content_fingerprint.Fingerprint,
        expected_content_line_count: usize,
        path: []u8,
        root: root_capability.RootCapability,
        temp_base_path: []u8,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.root.deinit();
            defer allocator.free(task.temp_base_path);

            var fingerprint = task.expected_fingerprint;
            var content_line_count = task.expected_content_line_count;
            var result: ChangeMapResult = .unavailable;
            var loaded = selected_document.load(task.root, task.path, allocator, io);
            defer loaded.deinit(allocator);
            var value = DocumentValue.fromLoaded(allocator, &loaded);
            defer value.deinit(allocator);
            switch (value) {
                .source => |*source| {
                    fingerprint = source.fingerprint;
                    content_line_count = source.contentLineCount();
                    if (task.expected_fingerprint.eql(fingerprint) and
                        task.expected_content_line_count == content_line_count)
                    {
                        result = loadChangeMap(
                            allocator,
                            io,
                            task.root.dir(),
                            task.path,
                            source,
                            task.temp_base_path,
                        );
                    }
                },
                .inert => {},
            }

            const finished = ChangeMapFinished{
                .identity = task.identity,
                .root_identity = task.root.identity,
                .generation = task.generation,
                .manifest_revision = task.manifest_revision,
                .source_revision = task.source_revision,
                .path = task.path,
                .fingerprint = fingerprint,
                .content_line_count = content_line_count,
                .result = result,
            };
            task.path = &.{};
            return .{ .repository = .{ .change_map_finished = finished } };
        }

        pub fn failed(ctx_ptr: *anyopaque, _: chasen.TaskFailure, allocator: std.mem.Allocator) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            defer task.root.deinit();
            defer allocator.free(task.temp_base_path);
            const finished = ChangeMapFinished{
                .identity = task.identity,
                .root_identity = task.root.identity,
                .generation = task.generation,
                .manifest_revision = task.manifest_revision,
                .source_revision = task.source_revision,
                .path = task.path,
                .fingerprint = task.expected_fingerprint,
                .content_line_count = task.expected_content_line_count,
                .result = .unavailable,
            };
            task.path = &.{};
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
    var backend: git_backend.LocalCommandBackend = .{};
    const loaded = backend.backend().loadRepositoryFileChange(allocator, io, .{
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
    var backend: git_backend.LocalCommandBackend = .{};
    const raw_manifest = backend.backend().loadRepositoryManifest(allocator, io, .{ .cwd = cwd }) catch
        return .{ .failed_static = "Repository manifest could not be loaded" };
    const raw_status = backend.backend().loadRepositoryFileStatus(allocator, io, .{ .cwd = cwd }) catch null;
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

pub const ApplyOutcome = enum { discarded, unchanged, changed, failed };

pub const MouseButton = enum { left, wheel_up, wheel_down };

pub const BodyPoint = struct { col: u16, row: u16 };

pub const BodyLayout = struct {
    tree_width: u16,
    header_rows: u16 = 1,

    pub fn treeRows(self: BodyLayout, body_height: u16) u16 {
        return body_height -| self.header_rows;
    }

    pub fn treeBodyRow(self: BodyLayout, point: BodyPoint) ?usize {
        if (point.col >= self.tree_width or point.row < self.header_rows) return null;
        return point.row - self.header_rows;
    }
};

pub fn bodyLayout(size: chasen.Size) BodyLayout {
    return .{ .tree_width = if (size.width < 24) size.width else @max(@as(u16, 12), size.width / 3) };
}

/// Page-owned state for the read-only current working-tree browser. The zero
/// value allocates nothing and is safe to deinitialize before first activation.
pub const RepositoryPageState = struct {
    initialized: bool = false,
    active: bool = false,
    activation_id: u64 = 0,
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,
    generation: u64 = 0,
    pending_generation: ?u64 = null,
    manifest_revision: u64 = 0,
    document_generation: u64 = 0,
    pending_document_generation: ?u64 = null,
    source_revision: u64 = 0,
    syntax_generation: u64 = 0,
    pending_syntax_generation: ?u64 = null,
    needs_syntax_request: bool = false,
    change_map_generation: u64 = 0,
    pending_change_map_generation: ?u64 = null,
    needs_change_map_request: bool = false,
    needs_revalidation: bool = false,
    needs_document_revalidation: bool = false,
    freshness: enum { unavailable, validating, fresh, failed } = .unavailable,
    load_state: LoadState = .idle,
    bundle: ?Bundle = null,
    displayed_document: ?DisplayedDocument = null,
    selected_path: ?[]const u8 = null,
    file_visibility: repository_tree.Visibility = .all,
    /// Owned raw path captured before entering Changed mode. It is deliberately
    /// independent from manifest generations so background replacement cannot
    /// leave a borrowed selection dangling before the user returns to All.
    all_selection_anchor: ?[]u8 = null,
    viewer: repository_model.ViewerState = .{},
    source_search: repository_model.SourceSearchState = .{},
    file_search: repository_model.FileSearchState = .{},
    status: app_state.StatusMessage = .{},

    pub fn deinit(self: *RepositoryPageState, allocator: std.mem.Allocator) void {
        if (self.bundle) |*bundle| bundle.deinit(allocator);
        if (self.displayed_document) |*document| document.deinit(allocator);
        if (self.all_selection_anchor) |anchor| allocator.free(anchor);
        self.* = .{};
    }

    pub fn activate(self: *RepositoryPageState, repo_epoch: u64, identity: ?root_capability.Identity) void {
        self.initialized = true;
        self.active = true;
        self.activation_id +%= 1;
        if (self.activation_id == 0) self.activation_id = 1;
        if (self.repo_epoch != repo_epoch) self.repo_epoch = repo_epoch;
        self.root_identity = identity;
        self.pending_document_generation = null;
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.needs_syntax_request = false;
        self.needs_change_map_request = false;
        self.needs_document_revalidation = false;
        if (identity == null) {
            self.needs_revalidation = false;
            self.freshness = .unavailable;
            self.load_state = .no_repository;
            return;
        }
        self.status.clear();
        self.needs_revalidation = true;
        self.freshness = .validating;
    }

    pub fn deactivate(self: *RepositoryPageState) void {
        self.active = false;
        if (self.bundle != null) self.freshness = .validating;
    }

    pub fn repositoryChanged(
        self: *RepositoryPageState,
        allocator: ?std.mem.Allocator,
        repo_epoch: u64,
        identity: ?root_capability.Identity,
    ) void {
        if (self.bundle) |*bundle| {
            const owner = allocator orelse @panic("Repository bundle replacement requires an allocator");
            bundle.deinit(owner);
        }
        self.bundle = null;
        if (self.displayed_document) |*document| {
            const owner = allocator orelse @panic("Repository document replacement requires an allocator");
            document.deinit(owner);
        }
        self.displayed_document = null;
        self.selected_path = null;
        if (self.all_selection_anchor) |anchor| {
            const owner = allocator orelse @panic("Repository selection-anchor replacement requires an allocator");
            owner.free(anchor);
        }
        self.all_selection_anchor = null;
        self.file_visibility = .all;
        self.viewer = .{};
        self.source_search.clear();
        self.file_search.close();
        self.pending_generation = null;
        self.pending_document_generation = null;
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.repo_epoch = repo_epoch;
        self.root_identity = identity;
        self.status.clear();
        self.load_state = if (identity != null) .idle else .no_repository;
        self.freshness = if (identity != null) .validating else .unavailable;
        self.needs_revalidation = self.active and identity != null;
        self.needs_document_revalidation = false;
        self.needs_syntax_request = false;
        self.needs_change_map_request = false;
    }

    pub fn prepareRequest(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        capability: *const root_capability.RootCapability,
    ) !Request {
        const owned_root = try allocator.dupe(u8, repo_root);
        errdefer allocator.free(owned_root);
        var root = try capability.duplicate();
        errdefer root.deinit();
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.pending_generation = self.generation;
        self.pending_document_generation = null;
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.needs_document_revalidation = false;
        self.needs_syntax_request = false;
        self.needs_change_map_request = false;
        self.needs_revalidation = false;
        self.freshness = .validating;
        if (self.bundle != null) self.status.set("Validating repository...", .{});
        if (self.bundle == null) self.load_state = .loading;
        return .{
            .identity = .{ .origin = .repository, .repo_epoch = self.repo_epoch, .activation_id = self.activation_id },
            .generation = self.generation,
            .root_path = owned_root,
            .root = root,
            .expected_fingerprint = if (self.bundle) |*bundle| bundle.document.fingerprint else null,
            .expected_status_fingerprint = if (self.bundle) |*bundle| bundle.status_fingerprint else null,
        };
    }

    pub fn prepareDocumentRequest(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        capability: *const root_capability.RootCapability,
    ) !DocumentRequest {
        const selected = self.selected_path orelse return error.NoSelectedDocument;
        const path = try allocator.dupe(u8, selected);
        errdefer allocator.free(path);
        var root = try capability.duplicate();
        errdefer root.deinit();
        self.document_generation +%= 1;
        if (self.document_generation == 0) self.document_generation = 1;
        self.pending_document_generation = self.document_generation;
        self.needs_document_revalidation = false;
        if (self.displayed_document != null) self.status.set("Validating selected file...", .{});
        return .{
            .identity = .{ .origin = .repository, .repo_epoch = self.repo_epoch, .activation_id = self.activation_id },
            .generation = self.document_generation,
            .manifest_revision = self.manifest_revision,
            .path = path,
            .root = root,
        };
    }

    pub fn prepareSyntaxRequest(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        capability: *const root_capability.RootCapability,
    ) !SyntaxRequest {
        if (!source_syntax_runtime.enabled) return error.SyntaxProviderDisabled;
        const displayed = self.displayed_document orelse return error.NoDisplayedSource;
        const source = switch (displayed.value) {
            .source => |source| source,
            .inert => return error.NoDisplayedSource,
        };
        const path = try allocator.dupe(u8, displayed.path);
        errdefer allocator.free(path);
        var root = try capability.duplicate();
        errdefer root.deinit();
        self.syntax_generation +%= 1;
        if (self.syntax_generation == 0) self.syntax_generation = 1;
        self.pending_syntax_generation = self.syntax_generation;
        self.needs_syntax_request = false;
        return .{
            .identity = .{ .origin = .repository, .repo_epoch = self.repo_epoch, .activation_id = self.activation_id },
            .generation = self.syntax_generation,
            .manifest_revision = displayed.manifest_revision,
            .source_revision = displayed.source_revision,
            .expected_fingerprint = source.fingerprint,
            .path = path,
            .root = root,
        };
    }

    pub fn prepareChangeMapRequest(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        capability: *const root_capability.RootCapability,
        temp_base_path: []const u8,
    ) !ChangeMapRequest {
        const displayed = self.displayed_document orelse return error.NoDisplayedSource;
        const source = switch (displayed.value) {
            .source => |source| source,
            .inert => return error.NoDisplayedSource,
        };
        if (!displayed.change_decoration.isEligible()) return error.ChangeMapNotEligible;
        const path = try allocator.dupe(u8, displayed.path);
        errdefer allocator.free(path);
        var root = try capability.duplicate();
        errdefer root.deinit();
        const owned_temp_base = try allocator.dupe(u8, temp_base_path);
        errdefer allocator.free(owned_temp_base);
        self.change_map_generation +%= 1;
        if (self.change_map_generation == 0) self.change_map_generation = 1;
        self.pending_change_map_generation = self.change_map_generation;
        self.needs_change_map_request = false;
        return .{
            .identity = .{ .origin = .repository, .repo_epoch = self.repo_epoch, .activation_id = self.activation_id },
            .generation = self.change_map_generation,
            .manifest_revision = displayed.manifest_revision,
            .source_revision = displayed.source_revision,
            .expected_fingerprint = source.fingerprint,
            .expected_content_line_count = source.contentLineCount(),
            .path = path,
            .root = root,
            .temp_base_path = owned_temp_base,
        };
    }

    pub fn rejectSpawn(self: *RepositoryPageState, generation: u64) void {
        if (self.pending_generation == generation) self.pending_generation = null;
        self.freshness = .failed;
        if (self.bundle == null) self.load_state = .failed;
        self.status.set("Could not start repository manifest task", .{});
    }

    pub fn rejectDocumentSpawn(self: *RepositoryPageState, generation: u64) void {
        if (self.pending_document_generation == generation) self.pending_document_generation = null;
        self.status.set("Could not start selected file task", .{});
    }

    pub fn rejectSyntaxSpawn(self: *RepositoryPageState, generation: u64) void {
        if (self.pending_syntax_generation != generation) return;
        self.pending_syntax_generation = null;
        // Task-start failure is transient and occurs before a provider verdict.
        // Preserve intent for a later event; maybeStart... is called only once
        // per update, so this does not create an immediate retry loop.
        self.needs_syntax_request = source_syntax_runtime.enabled and self.currentSource() != null;
    }

    pub fn rejectChangeMapSpawn(self: *RepositoryPageState, generation: u64) void {
        if (self.pending_change_map_generation != generation) return;
        self.pending_change_map_generation = null;
        self.needs_change_map_request = self.currentSource() != null;
    }

    pub fn requestReload(self: *RepositoryPageState, has_repository: bool) void {
        self.pending_document_generation = null;
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.needs_document_revalidation = false;
        self.needs_syntax_request = false;
        self.needs_change_map_request = false;
        if (!has_repository) {
            self.needs_revalidation = false;
            self.freshness = .unavailable;
            self.load_state = .no_repository;
            self.status.set("Repository required", .{});
            return;
        }
        self.needs_revalidation = true;
    }

    pub fn wantsManifestRequest(self: *const RepositoryPageState) bool {
        return self.active and self.needs_revalidation;
    }

    pub fn wantsDocumentRequest(self: *const RepositoryPageState) bool {
        return self.active and self.needs_document_revalidation and
            self.pending_generation == null and self.pending_document_generation == null and
            self.selected_path != null and self.root_identity != null;
    }

    pub fn wantsSyntaxRequest(self: *const RepositoryPageState) bool {
        return source_syntax_runtime.enabled and self.active and self.needs_syntax_request and
            self.pending_generation == null and self.pending_document_generation == null and
            self.pending_syntax_generation == null and self.displayed_document != null and
            self.root_identity != null;
    }

    pub fn wantsChangeMapRequest(self: *const RepositoryPageState) bool {
        return self.active and self.needs_change_map_request and
            self.pending_generation == null and self.pending_document_generation == null and
            self.pending_change_map_generation == null and self.displayed_document != null and
            self.root_identity != null;
    }

    pub fn markRequestPreparationFailed(self: *RepositoryPageState, err: anyerror) void {
        self.freshness = .failed;
        if (self.bundle == null) self.load_state = .failed;
        self.status.set("Could not prepare repository manifest: {s}", .{@errorName(err)});
    }

    pub fn markDocumentRequestPreparationFailed(self: *RepositoryPageState, err: anyerror) void {
        self.status.set("Could not prepare selected file: {s}", .{@errorName(err)});
    }

    pub fn markSyntaxRequestPreparationFailed(self: *RepositoryPageState) void {
        self.pending_syntax_generation = null;
        // Preparation failure has the same retry semantics as spawn failure.
        // Parser/query/metadata failure is different: its delivered completion
        // consumes intent and deliberately leaves the plain source terminal.
        self.needs_syntax_request = source_syntax_runtime.enabled and self.currentSource() != null;
    }

    pub fn markChangeMapRequestPreparationFailed(self: *RepositoryPageState) void {
        self.pending_change_map_generation = null;
        self.needs_change_map_request = self.currentSource() != null;
    }

    pub fn repositoryCommitFailed(self: *RepositoryPageState) void {
        if (self.bundle == null) self.load_state = .failed;
        self.freshness = .failed;
        self.status.set("Repository root could not be opened safely", .{});
    }

    pub fn applyFinished(self: *RepositoryPageState, allocator: std.mem.Allocator, finished: *ManifestFinished) ApplyOutcome {
        if (finished.identity.origin != .repository or
            finished.identity.repo_epoch != self.repo_epoch or
            finished.identity.activation_id != self.activation_id or
            finished.generation != self.generation or
            self.pending_generation != finished.generation)
        {
            return .discarded;
        }
        self.pending_generation = null;
        const expected_root = self.root_identity orelse {
            self.acceptFailure("Repository root changed");
            return .failed;
        };
        if (!expected_root.eql(finished.root_identity)) {
            self.acceptFailure("Repository root changed");
            return .failed;
        }
        switch (finished.result) {
            .unchanged => {
                const changed_status_message = self.file_visibility == .changed and
                    self.bundle != null and !self.bundle.?.status_available;
                self.freshness = if (self.active) .fresh else .validating;
                self.needs_document_revalidation = self.selected_path != null;
                self.status.clear();
                return if (changed_status_message) .changed else .unchanged;
            },
            .status_changed => |*update| {
                const bundle = if (self.bundle) |*owned| owned else {
                    // A status-only completion is only valid against a retained
                    // manifest. Treat an impossible orphan as optional loss;
                    // its owned payload remains with `finished.deinit`.
                    self.freshness = if (self.active) .fresh else .validating;
                    self.status.clear();
                    return .unchanged;
                };
                const previous_selected = self.selected_path;
                const previous_status_available = bundle.status_available;
                const visible_changed = switch (update.*) {
                    .loaded => |*index| blk: {
                        const changed = bundle.tree.applyChangeIndex(index);
                        bundle.status_fingerprint = index.fingerprint;
                        bundle.status_available = true;
                        index.deinit(allocator);
                        update.* = .unavailable;
                        break :blk changed;
                    },
                    .unavailable => blk: {
                        bundle.status_fingerprint = null;
                        bundle.status_available = false;
                        break :blk bundle.tree.clearChangeIndex();
                    },
                };
                const selection_changed = if (self.file_visibility == .changed)
                    self.rebuildTreeProjection(previous_selected, false, 0)
                else
                    false;
                // Status-only refresh does not change manifest/source identity,
                // but Changed projection may move or clear selection when a file
                // leaves the status set. Preserve the source only when its raw
                // path identity survived that projection.
                if (selection_changed)
                    self.invalidateSelectedDocument(allocator)
                else
                    self.needs_document_revalidation = self.selected_path != null;
                self.freshness = if (self.active) .fresh else .validating;
                self.status.clear();
                const status_availability_changed = self.file_visibility == .changed and
                    previous_status_available != bundle.status_available;
                const changed_status_message = self.file_visibility == .changed and !bundle.status_available;
                return if (visible_changed or selection_changed or status_availability_changed or changed_status_message) .changed else .unchanged;
            },
            .loaded => |*incoming| {
                self.replaceBundle(allocator, incoming) catch |err| {
                    self.acceptFailure(@errorName(err));
                    return .failed;
                };
                finished.result = .{ .unchanged = self.bundle.?.document.fingerprint };
                self.manifest_revision +%= 1;
                if (self.manifest_revision == 0) self.manifest_revision = 1;
                self.pending_document_generation = null;
                self.pending_syntax_generation = null;
                self.pending_change_map_generation = null;
                self.needs_syntax_request = false;
                self.needs_change_map_request = false;
                self.needs_document_revalidation = self.selected_path != null;
                if (self.displayed_document) |*document| document.deinit(allocator);
                self.displayed_document = null;
                self.freshness = if (self.active) .fresh else .validating;
                self.status.clear();
                return .changed;
            },
            .failed_static => |message| {
                self.acceptFailure(message);
                return .failed;
            },
        }
    }

    pub fn applyDocumentFinished(self: *RepositoryPageState, allocator: std.mem.Allocator, finished: *DocumentFinished) ApplyOutcome {
        if (finished.identity.origin != .repository or
            finished.identity.repo_epoch != self.repo_epoch or
            finished.identity.activation_id != self.activation_id or
            finished.generation != self.document_generation or
            self.pending_document_generation != finished.generation or
            finished.manifest_revision != self.manifest_revision)
        {
            return .discarded;
        }
        self.pending_document_generation = null;
        const expected_root = self.root_identity orelse return .failed;
        if (!expected_root.eql(finished.root_identity)) {
            self.status.set("Repository root changed", .{});
            return .failed;
        }
        const selected = self.selected_path orelse return .discarded;
        if (!std.mem.eql(u8, selected, finished.path)) return .discarded;

        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.source_revision +%= 1;
        if (self.source_revision == 0) self.source_revision = 1;
        if (self.displayed_document) |*previous| previous.deinit(allocator);
        self.displayed_document = .{
            .path = finished.path,
            .manifest_revision = finished.manifest_revision,
            .source_revision = self.source_revision,
            .value = finished.value,
            .change_decoration = switch (finished.value) {
                .source => .eligible,
                .inert => .terminal_plain,
            },
        };
        finished.path = &.{};
        finished.value = .{ .inert = .unreadable };
        self.viewer.resetSource();
        if (self.currentSource() == null) self.viewer.focus = .tree;
        self.source_search.clear();
        self.needs_syntax_request = source_syntax_runtime.enabled and self.currentSource() != null;
        self.needs_change_map_request = self.currentSource() != null;
        self.status.clear();
        return .changed;
    }

    pub fn applySyntaxFinished(self: *RepositoryPageState, allocator: std.mem.Allocator, finished: *SyntaxFinished) ApplyOutcome {
        if (finished.identity.origin != .repository or
            finished.identity.repo_epoch != self.repo_epoch or
            finished.identity.activation_id != self.activation_id or
            finished.generation != self.syntax_generation or
            self.pending_syntax_generation != finished.generation or
            finished.manifest_revision != self.manifest_revision)
        {
            return .discarded;
        }
        self.pending_syntax_generation = null;
        const expected_root = self.root_identity orelse return .discarded;
        if (!expected_root.eql(finished.root_identity)) return .discarded;
        const displayed = if (self.displayed_document) |*document| document else return .discarded;
        if (displayed.source_revision != finished.source_revision or
            displayed.manifest_revision != finished.manifest_revision or
            !std.mem.eql(u8, displayed.path, finished.path)) return .discarded;
        const source = switch (displayed.value) {
            .source => |*source| source,
            .inert => return .discarded,
        };
        if (!source.fingerprint.eql(finished.fingerprint)) return .discarded;
        switch (finished.result) {
            .loaded => |spans| {
                displayed.syntax_spans.deinit(allocator);
                displayed.syntax_spans = spans;
                finished.result = .unavailable;
                return .changed;
            },
            .unavailable => return .unchanged,
        }
    }

    pub fn applyChangeMapFinished(self: *RepositoryPageState, allocator: std.mem.Allocator, finished: *ChangeMapFinished) ApplyOutcome {
        if (finished.identity.origin != .repository or
            finished.identity.repo_epoch != self.repo_epoch or
            finished.identity.activation_id != self.activation_id or
            finished.generation != self.change_map_generation or
            self.pending_change_map_generation != finished.generation or
            finished.manifest_revision != self.manifest_revision)
        {
            return .discarded;
        }
        self.pending_change_map_generation = null;
        const expected_root = self.root_identity orelse return .discarded;
        if (!expected_root.eql(finished.root_identity)) return .discarded;
        const displayed = if (self.displayed_document) |*document| document else return .discarded;
        if (displayed.source_revision != finished.source_revision or
            displayed.manifest_revision != finished.manifest_revision or
            !std.mem.eql(u8, displayed.path, finished.path)) return .discarded;
        const source = switch (displayed.value) {
            .source => |*source| source,
            .inert => return .discarded,
        };
        if (!source.fingerprint.eql(finished.fingerprint) or
            source.contentLineCount() != finished.content_line_count)
        {
            // The independent task snapshot observed a newer file than the
            // accepted source. Do not attach its rows to old coordinates;
            // request a fresh primary document before trying decoration again.
            self.needs_document_revalidation = true;
            return .discarded;
        }
        if (!displayed.change_decoration.isEligible()) return .discarded;

        displayed.change_decoration.deinit(allocator);
        switch (finished.result) {
            .loaded => |map| {
                displayed.change_decoration = .{ .resolved = map };
                finished.result = .unavailable;
                return .changed;
            },
            .unavailable => {
                displayed.change_decoration = .terminal_plain;
                return .unchanged;
            },
        }
    }

    fn replaceBundle(self: *RepositoryPageState, allocator: std.mem.Allocator, incoming: *Bundle) !void {
        const previous_selected = self.selected_path;
        const selected = if (self.bundle) |*previous|
            try incoming.tree.restoreStateFrom(allocator, &previous.tree, previous_selected)
        else
            incoming.tree.firstFilePath();

        if (self.bundle) |*previous| previous.deinit(allocator);
        self.bundle = incoming.*;
        incoming.* = undefined;
        self.selected_path = selected;
        self.load_state = if (self.bundle.?.document.paths.len == 0) .empty else .loaded;
        if (self.file_visibility == .all) {
            self.bundle.?.tree.rebuildVisible();
            self.viewer.tree_cursor = if (selected) |path| self.bundle.?.tree.visibleIndexForPath(path) orelse 0 else 0;
            if (self.file_search.mode) {
                repository_navigation.refreshFileSearch(&self.file_search, &self.bundle.?.tree, .all);
            }
            self.clampScroll(0);
        } else {
            _ = self.rebuildTreeProjection(selected, false, 0);
        }
    }

    /// Rebuilds only the page-visible tree and resolves selection against that
    /// projection. The raw manifest and collapse flags remain authoritative;
    /// switching filters therefore cannot destroy the user's All-mode shape.
    fn rebuildTreeProjection(
        self: *RepositoryPageState,
        preferred: ?[]const u8,
        reveal_preferred: bool,
        body_height: u16,
    ) bool {
        const previous = self.selected_path;
        const bundle = if (self.bundle) |*owned| owned else {
            self.selected_path = null;
            self.viewer.tree_cursor = 0;
            self.viewer.tree_vertical_scroll = 0;
            self.file_search.resetResults();
            return !optionalPathEql(previous, null);
        };
        const tree = &bundle.tree;
        tree.rebuildVisibleFor(self.file_visibility);

        const status_usable = self.file_visibility == .all or bundle.status_available;
        const retained = if (status_usable and preferred != null)
            tree.filePath(preferred.?, self.file_visibility)
        else
            null;
        const selected = retained orelse if (status_usable)
            tree.firstFilePathFor(self.file_visibility)
        else
            null;
        self.selected_path = selected;

        if (selected) |path| {
            var visible = tree.visibleIndexForPath(path);
            if (visible == null and (reveal_preferred or retained == null)) {
                if (tree.nodeIndexForPath(path, self.file_visibility)) |node_index| {
                    visible = tree.revealNodeFor(node_index, self.file_visibility);
                }
            }
            if (visible) |index| self.viewer.tree_cursor = index;
        } else {
            self.viewer.tree_cursor = 0;
            self.viewer.tree_vertical_scroll = 0;
            if (self.currentSource() == null) self.viewer.focus = .tree;
        }
        if (self.file_search.mode) {
            repository_navigation.refreshFileSearch(&self.file_search, tree, self.file_visibility);
        }
        self.clampScroll(body_height);
        return !optionalPathEql(previous, self.selected_path);
    }

    fn toggleChangedFilter(self: *RepositoryPageState, allocator: std.mem.Allocator, body_height: u16) void {
        switch (self.file_visibility) {
            .all => {
                const anchor = if (self.selected_path) |path|
                    allocator.dupe(u8, path) catch {
                        self.status.set("Could not preserve All selection", .{});
                        return;
                    }
                else
                    null;
                if (self.all_selection_anchor) |previous| allocator.free(previous);
                self.all_selection_anchor = anchor;
                self.file_visibility = .changed;
                _ = self.rebuildTreeProjection(self.selected_path, true, body_height);
            },
            .changed => {
                const anchor = self.all_selection_anchor;
                const preferred = if (anchor) |path| blk: {
                    const tree = if (self.bundle) |*bundle| &bundle.tree else break :blk self.selected_path;
                    break :blk tree.filePath(path, .all) orelse self.selected_path;
                } else self.selected_path;
                self.file_visibility = .all;
                _ = self.rebuildTreeProjection(preferred, true, body_height);
                if (anchor) |owned| allocator.free(owned);
                self.all_selection_anchor = null;
            },
        }
    }

    fn acceptFailure(self: *RepositoryPageState, message: []const u8) void {
        self.freshness = .failed;
        if (self.bundle == null) self.load_state = .failed;
        self.status.set("{s}", .{message});
    }

    pub fn applyNavigation(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        msg: Msg,
        body_size: chasen.Size,
    ) bool {
        const previous = self.selected_path;
        const body_height = bodyLayout(body_size).treeRows(body_size.height);
        const source = self.currentSource();
        const right_width = body_size.width -| bodyLayout(body_size).tree_width -| 1;
        const source_text_width = if (source) |document| repository_view.sourceTextWidth(right_width, document, self.viewer.line_numbers) else 0;
        switch (msg) {
            .move_up => if (self.viewer.focus == .source and source != null)
                repository_navigation.moveSource(&self.viewer, source.?, -1, body_size.height)
            else
                self.moveCursor(-1, body_height),
            .move_down => if (self.viewer.focus == .source and source != null)
                repository_navigation.moveSource(&self.viewer, source.?, 1, body_size.height)
            else
                self.moveCursor(1, body_height),
            .wheel_up => {
                self.viewer.focus = .tree;
                self.moveCursor(-1, body_height);
            },
            .wheel_down => {
                self.viewer.focus = .tree;
                self.moveCursor(1, body_height);
            },
            .page_up => if (self.viewer.focus == .source and source != null)
                repository_navigation.pageSource(&self.viewer, source.?, -1, body_size.height)
            else
                self.moveCursor(-@as(isize, @intCast(@max(body_height -| 1, 1))), body_height),
            .page_down => if (self.viewer.focus == .source and source != null)
                repository_navigation.pageSource(&self.viewer, source.?, 1, body_size.height)
            else
                self.moveCursor(@intCast(@max(body_height -| 1, 1)), body_height),
            .toggle_directory => self.toggleCursor(body_height),
            .scroll_left => if (self.viewer.focus == .source and source != null) {
                repository_navigation.scrollSourceHorizontal(&self.viewer, source.?, -8, source_text_width);
            } else {
                self.viewer.tree_horizontal_scroll -|= 4;
            },
            .scroll_right => if (self.viewer.focus == .source and source != null) {
                repository_navigation.scrollSourceHorizontal(&self.viewer, source.?, 8, source_text_width);
            } else {
                self.viewer.tree_horizontal_scroll = @min(self.viewer.tree_horizontal_scroll +| 4, manifest.max_path_bytes * 4);
            },
            .mouse_row => |row| {
                self.viewer.focus = .tree;
                self.setCursor(row, body_height, false);
            },
            .mouse_toggle_row => |row| {
                self.viewer.focus = .tree;
                self.setCursor(row, body_height, true);
            },
            .mouse_source_row => |row| if (source) |document| {
                self.viewer.focus = .source;
                self.viewer.source_cursor = @min(self.viewer.source_vertical_scroll + row, document.rowCount() - 1);
                repository_navigation.clampSource(&self.viewer, document, body_size.height, source_text_width);
            },
            .mouse_source_wheel_up => if (source) |document| {
                self.viewer.focus = .source;
                repository_navigation.moveSource(&self.viewer, document, -1, body_size.height);
            },
            .mouse_source_wheel_down => if (source) |document| {
                self.viewer.focus = .source;
                repository_navigation.moveSource(&self.viewer, document, 1, body_size.height);
            },
            .focus_tree => self.viewer.focus = .tree,
            .focus_source => if (source != null) {
                self.viewer.focus = .source;
            },
            .toggle_focus => if (source != null) {
                self.viewer.focus = if (self.viewer.focus == .tree) .source else .tree;
            },
            .tree_first => self.selectTreeEdge(false, body_height),
            .tree_last => self.selectTreeEdge(true, body_height),
            .source_first => if (source) |document| repository_navigation.firstSource(&self.viewer, document, body_size.height),
            .source_last => if (source) |document| repository_navigation.lastSource(&self.viewer, document, body_size.height),
            .toggle_changed_filter => self.toggleChangedFilter(allocator, body_height),
            .toggle_line_numbers => {
                self.viewer.line_numbers = !self.viewer.line_numbers;
                if (source) |document| repository_navigation.clampSource(&self.viewer, document, body_size.height, repository_view.sourceTextWidth(right_width, document, self.viewer.line_numbers));
            },
            .enter_source_search => if (source != null) {
                self.source_search.mode = true;
                self.source_search.input = self.source_search.query;
                self.viewer.focus = .source;
            },
            .cancel_source_search => {
                self.source_search.mode = false;
                self.source_search.input = .{};
            },
            .submit_source_search => if (source) |document| {
                self.source_search.mode = false;
                self.source_search.query = self.source_search.input;
                self.source_search.match = document.findNext(self.source_search.query.slice(), null);
                if (self.source_search.match) |match| repository_navigation.revealMatch(&self.viewer, document, match, body_size.height, source_text_width) else self.status.set("No source match", .{});
            },
            .clear_source_search => self.source_search.clear(),
            .next_source_match => if (source) |document| {
                self.source_search.match = document.findNext(self.source_search.query.slice(), self.source_search.match);
                if (self.source_search.match) |match| repository_navigation.revealMatch(&self.viewer, document, match, body_size.height, source_text_width);
            },
            .previous_source_match => if (source) |document| {
                self.source_search.match = document.findPrevious(self.source_search.query.slice(), self.source_search.match);
                if (self.source_search.match) |match| repository_navigation.revealMatch(&self.viewer, document, match, body_size.height, source_text_width);
            },
            .source_search_backspace => self.source_search.input.backspace(),
            .source_search_move_left => self.source_search.input.moveLeft(),
            .source_search_move_right => self.source_search.input.moveRight(),
            .source_search_insert => |codepoint| self.source_search.input.insert(codepoint) catch self.status.set("Source search is too long", .{}),
            .source_search_paste => |text| self.source_search.input.insertSlice(text) catch self.status.set("Source search is too long", .{}),
            .enter_file_search => {
                self.file_search.mode = true;
                self.file_search.input = .{};
                if (self.bundle) |*bundle| repository_navigation.refreshFileSearch(&self.file_search, &bundle.tree, self.file_visibility);
            },
            .cancel_file_search => self.file_search.close(),
            .submit_file_search => self.submitFileSearch(body_height),
            .file_search_previous => self.file_search.move(-1),
            .file_search_next => self.file_search.move(1),
            .file_search_backspace => {
                self.file_search.input.backspace();
                if (self.bundle) |*bundle| repository_navigation.refreshFileSearch(&self.file_search, &bundle.tree, self.file_visibility);
            },
            .file_search_insert => |codepoint| {
                self.file_search.input.insert(codepoint) catch {
                    self.status.set("File search is too long", .{});
                    return false;
                };
                if (self.bundle) |*bundle| repository_navigation.refreshFileSearch(&self.file_search, &bundle.tree, self.file_visibility);
            },
            .file_search_paste => |text| {
                self.file_search.input.insertSlice(text) catch {
                    self.status.set("File search is too long", .{});
                    return false;
                };
                if (self.bundle) |*bundle| repository_navigation.refreshFileSearch(&self.file_search, &bundle.tree, self.file_visibility);
            },
            .manifest_finished, .document_finished, .syntax_finished, .change_map_finished => unreachable,
        }
        if (optionalPathEql(previous, self.selected_path)) return false;
        self.invalidateSelectedDocument(allocator);
        return true;
    }

    fn invalidateSelectedDocument(self: *RepositoryPageState, allocator: std.mem.Allocator) void {
        self.pending_document_generation = null;
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.needs_syntax_request = false;
        self.needs_change_map_request = false;
        self.needs_document_revalidation = self.selected_path != null;
        if (self.displayed_document) |*document| document.deinit(allocator);
        self.displayed_document = null;
        self.viewer.resetSource();
        self.source_search.clear();
    }

    fn currentSource(self: *const RepositoryPageState) ?*const source_document.Document {
        const displayed = if (self.displayed_document) |*document| document else return null;
        const selected = self.selected_path orelse return null;
        if (displayed.manifest_revision != self.manifest_revision or !std.mem.eql(u8, displayed.path, selected)) return null;
        return switch (displayed.value) {
            .source => |*source| source,
            .inert => null,
        };
    }

    pub fn inputContext(self: *const RepositoryPageState, keymap: @import("keymap").Effective) repository_input.Context {
        const source_available = self.currentSource() != null;
        return .{
            .focus = if (source_available) self.viewer.focus else .tree,
            .source_available = source_available,
            .source_search_mode = self.source_search.mode,
            .file_search_mode = self.file_search.mode,
            .source_query_len = self.source_search.query.len,
            .keymap = keymap,
        };
    }

    fn selectTreeEdge(self: *RepositoryPageState, last: bool, body_height: u16) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        if (tree.visible_len == 0) return;
        if (last) {
            var index = tree.visible_len;
            while (index > 0) {
                index -= 1;
                if (tree.nodes[tree.visible[index]].kind == .file) {
                    self.viewer.tree_cursor = index;
                    break;
                }
            }
        } else {
            for (tree.visibleNodes(), 0..) |node_index, visible_index| if (tree.nodes[node_index].kind == .file) {
                self.viewer.tree_cursor = visible_index;
                break;
            };
        }
        self.viewer.focus = .tree;
        self.selectCursor();
        self.clampScroll(body_height);
    }

    fn submitFileSearch(self: *RepositoryPageState, body_height: u16) void {
        const node_index = self.file_search.selectedNode() orelse {
            self.file_search.no_match = true;
            return;
        };
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        const visible = tree.revealNodeFor(node_index, self.file_visibility) orelse return;
        self.viewer.tree_cursor = visible;
        self.viewer.focus = .tree;
        self.selected_path = tree.nodes[node_index].path;
        self.file_search.close();
        self.clampScroll(body_height);
    }

    fn moveCursor(self: *RepositoryPageState, delta: isize, body_height: u16) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        if (tree.visible_len == 0) return;
        if (delta < 0) self.viewer.tree_cursor -|= @intCast(-delta) else self.viewer.tree_cursor = @min(self.viewer.tree_cursor +| @as(usize, @intCast(delta)), tree.visible_len - 1);
        self.selectCursor();
        self.clampScroll(body_height);
    }

    fn setCursor(self: *RepositoryPageState, body_row: usize, body_height: u16, toggle: bool) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        const index = self.viewer.tree_vertical_scroll + body_row;
        if (index >= tree.visible_len) return;
        self.viewer.tree_cursor = index;
        if (toggle and tree.nodes[tree.visible[index]].kind == .directory) self.toggleCursor(body_height) else self.selectCursor();
    }

    fn toggleCursor(self: *RepositoryPageState, body_height: u16) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        if (tree.toggleVisibleFor(self.viewer.tree_cursor, self.file_visibility)) {
            if (tree.visible_len > 0) self.viewer.tree_cursor = @min(self.viewer.tree_cursor, tree.visible_len - 1);
            self.clampScroll(body_height);
        } else self.selectCursor();
    }

    fn selectCursor(self: *RepositoryPageState) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        if (self.viewer.tree_cursor >= tree.visible_len) return;
        const node = tree.nodes[tree.visible[self.viewer.tree_cursor]];
        if (node.kind == .file) self.selected_path = node.path;
    }

    pub fn clampScroll(self: *RepositoryPageState, body_height: u16) void {
        const visible_len = if (self.bundle) |*bundle| bundle.tree.visible_len else 0;
        if (visible_len == 0) {
            self.viewer.tree_cursor = 0;
            self.viewer.tree_vertical_scroll = 0;
            return;
        }
        self.viewer.tree_cursor = @min(self.viewer.tree_cursor, visible_len - 1);
        const rows: usize = @max(@as(usize, body_height), 1);
        if (self.viewer.tree_cursor < self.viewer.tree_vertical_scroll) self.viewer.tree_vertical_scroll = self.viewer.tree_cursor;
        if (self.viewer.tree_cursor >= self.viewer.tree_vertical_scroll + rows) self.viewer.tree_vertical_scroll = self.viewer.tree_cursor - rows + 1;
        self.viewer.tree_vertical_scroll = @min(self.viewer.tree_vertical_scroll, visible_len -| rows);
    }

    pub fn clampForBodySize(self: *RepositoryPageState, body_size: chasen.Size) void {
        const layout = bodyLayout(body_size);
        self.clampScroll(layout.treeRows(body_size.height));
        if (self.currentSource()) |document| {
            const right_width = body_size.width -| layout.tree_width -| 1;
            const text_width = repository_view.sourceTextWidth(right_width, document, self.viewer.line_numbers);
            repository_navigation.clampSource(&self.viewer, document, body_size.height, text_width);
        }
    }

    pub fn mouseToMsg(self: *const RepositoryPageState, point: BodyPoint, button: MouseButton, size: chasen.Size) ?Msg {
        const layout = bodyLayout(size);
        if (point.col < layout.tree_width) return switch (button) {
            .wheel_up => .wheel_up,
            .wheel_down => .wheel_down,
            .left => blk: {
                const body_row = layout.treeBodyRow(point) orelse return .focus_tree;
                const tree = if (self.bundle) |*bundle| &bundle.tree else return null;
                const visible_index = self.viewer.tree_vertical_scroll + body_row;
                if (visible_index >= tree.visible_len) return null;
                const node = tree.nodes[tree.visible[visible_index]];
                break :blk if (node.kind == .directory)
                    .{ .mouse_toggle_row = body_row }
                else
                    .{ .mouse_row = body_row };
            },
        };
        if (point.col == layout.tree_width or self.currentSource() == null) return null;
        return switch (button) {
            .wheel_up => .mouse_source_wheel_up,
            .wheel_down => .mouse_source_wheel_down,
            .left => if (point.row >= 2) .{ .mouse_source_row = point.row - 2 } else .focus_source,
        };
    }
};

fn optionalPathEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

pub fn keyToMsg(context: repository_input.Context, key: chasen.Key) ?Msg {
    return repository_input.keyToMsg(Msg, context, key);
}

pub fn pasteToMsg(context: repository_input.Context, text: []const u8) ?Msg {
    return repository_input.pasteToMsg(Msg, context, text);
}

pub const ViewContext = struct {
    page_state: *const RepositoryPageState,
    palette: theme.Palette,
};

pub fn view(context: ViewContext, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    const state = context.page_state;
    switch (state.load_state) {
        .idle, .no_repository, .failed => {
            const label: []const u8 = switch (state.load_state) {
                .idle => "Repository not loaded",
                .no_repository => "Repository required",
                .failed => if (state.status.text().len > 0) state.status.text() else "Repository manifest failed",
                else => unreachable,
            };
            draw.copyClippedTextAt(surface, 1, size.height / 2, label, context.palette.style(if (state.load_state == .failed) .danger else .muted)) catch {};
            return;
        },
        .loading => if (state.file_visibility == .all) {
            draw.copyClippedTextAt(surface, 1, size.height / 2, "Loading repository files...", context.palette.style(.muted)) catch {};
            return;
        },
        .empty => if (state.file_visibility == .all) {
            draw.copyClippedTextAt(surface, 1, size.height / 2, "Repository has no tracked or non-ignored files", context.palette.style(.muted)) catch {};
            return;
        },
        .loaded => {},
    }

    const layout = bodyLayout(size);
    const left_width = layout.tree_width;
    var left = surface.child(.{ .col = 0, .row = 0, .width = left_width, .height = size.height });
    const tree_header: []const u8 = if (state.file_visibility == .changed) "Repository files [changed]" else "Repository files";
    draw.copyClippedTextAt(&left, 1, 0, tree_header, context.palette.boldStyle(.accent)) catch {};
    if (left_width < size.width) {
        var separator_row: u16 = 0;
        while (separator_row < size.height) : (separator_row += 1) _ = surface.borrowTextAt(left_width, separator_row, "│", context.palette.style(.muted));
    }
    if (state.load_state == .loading) {
        if (size.height > 1) draw.copyClippedTextAt(&left, 1, 1, "Loading changed files...", context.palette.style(.muted)) catch {};
        return;
    }

    const tree = &state.bundle.?.tree;
    const rows = layout.treeRows(size.height);
    const changed_message: ?[]const u8 = if (state.file_visibility == .all)
        null
    else if (!treeStatusAvailable(state))
        if (state.freshness == .validating) "Loading changed files..." else "Changed-file status unavailable; press r to retry"
    else if (tree.visible_len == 0)
        "No changed files"
    else
        null;
    if (changed_message) |message| {
        if (size.height > 1) draw.copyClippedTextAt(&left, 1, 1, message, context.palette.style(.muted)) catch {};
    } else {
        var body_row: usize = 0;
        while (body_row < rows and state.viewer.tree_vertical_scroll + body_row < tree.visible_len) : (body_row += 1) {
            const visible_index = state.viewer.tree_vertical_scroll + body_row;
            const node = tree.nodes[tree.visible[visible_index]];
            const visible_text = try treeRowTextAlloc(
                surface.frameAllocator(),
                node,
                state.viewer.tree_horizontal_scroll,
                left_width -| 1,
            );
            const style = if (visible_index == state.viewer.tree_cursor)
                context.palette.boldStyle(.prompt)
            else if (node.kind == .directory)
                context.palette.boldStyle(.accent)
            else if (node.file_change) |change|
                context.palette.style(switch (change) {
                    .added => .diff_added,
                    .modified => .diff_modified,
                })
            else
                context.palette.style(.foreground);
            draw.copyClippedTextAt(&left, 1, @intCast(body_row + 1), visible_text, style) catch {};
        }
    }

    if (left_width + 1 >= size.width) return;
    var right = surface.child(.{ .col = left_width + 1, .row = 0, .width = size.width - left_width - 1, .height = size.height });
    if (state.file_search.mode) {
        try repository_view.drawFileSearch(&right, tree, &state.file_search, context.palette);
        return;
    }
    if (state.selected_path) |path| {
        const path_window = try manifest.displayWindowAlloc(surface.frameAllocator(), path, 0, right.size().width -| 1);
        draw.copyClippedTextAt(&right, 1, 0, path_window.text(), context.palette.boldStyle(.accent)) catch {};
        if (size.height > 2) try drawDocumentCheckpoint(state, path, &right, context.palette);
    } else {
        draw.copyClippedTextAt(&right, 1, 0, "No file selected", context.palette.style(.muted)) catch {};
    }
}

fn treeStatusAvailable(state: *const RepositoryPageState) bool {
    return if (state.bundle) |bundle| bundle.status_available else false;
}

fn drawDocumentCheckpoint(
    state: *const RepositoryPageState,
    selected_path: []const u8,
    surface: *chasen.Surface,
    palette: theme.Palette,
) !void {
    const displayed = state.displayed_document orelse {
        draw.copyClippedTextAt(surface, 1, 2, "Loading selected file...", palette.style(.muted)) catch {};
        return;
    };
    if (displayed.manifest_revision != state.manifest_revision or !std.mem.eql(u8, displayed.path, selected_path)) {
        draw.copyClippedTextAt(surface, 1, 2, "Loading selected file...", palette.style(.muted)) catch {};
        return;
    }
    switch (displayed.value) {
        .source => |*source| {
            try repository_view.drawSource(
                surface,
                source,
                &displayed.syntax_spans,
                displayed.change_decoration.map(),
                state.viewer,
                state.source_search,
                palette,
            );
            return;
        },
        .inert => |inert| drawInertCheckpoint(inert, surface, palette),
    }
}

fn drawInertCheckpoint(value: selected_document.Value, surface: *chasen.Surface, palette: theme.Palette) void {
    const label: []const u8 = switch (value) {
        .text => unreachable,
        .symlink => |link| blk: {
            const width = surface.size().width -| "Symbolic link -> ".len -| 1;
            const target = manifest.displayWindowAlloc(surface.frameAllocator(), link.target, 0, width) catch break :blk "Symbolic link";
            break :blk std.fmt.allocPrint(surface.frameAllocator(), "Symbolic link -> {s}", .{target.text()}) catch "Symbolic link";
        },
        .binary => "Binary file is not shown",
        .invalid_utf8 => "Non-UTF-8 file is not shown",
        .unsafe_control_text => "File contains unsupported control characters",
        .oversized => "File exceeds the 1 MiB display limit",
        .directory_or_gitlink => "Submodule or directory is not shown",
        .named_pipe, .unix_socket, .block_device, .character_device, .unknown_special => "Special file is not shown",
        .missing_or_changed => "File changed or disappeared; press r to retry",
        .unreadable, .unsupported_platform => "Selected file could not be read",
    };
    draw.copyClippedTextAt(surface, 1, 2, label, palette.style(.muted)) catch {};
}

fn treeRowTextAlloc(
    allocator: std.mem.Allocator,
    node: repository_tree.Node,
    horizontal_scroll: usize,
    width: u16,
) ![]const u8 {
    if (width == 0) return "";
    const available: usize = width;
    const logical_indent = node.depth * 2;
    const marker: []const u8 = switch (node.kind) {
        .file => "  ",
        .directory => if (node.expanded) "▾ " else "▸ ",
    };
    const marker_width = chasen.text.displayWidth(marker);
    var skip = horizontal_scroll;
    var indent_columns: usize = 0;
    var visible_marker: []const u8 = marker;
    if (skip < logical_indent) {
        indent_columns = @min(logical_indent - skip, available);
        skip = 0;
    } else {
        skip -= logical_indent;
        if (skip >= marker_width) {
            skip -= marker_width;
            visible_marker = "";
        } else if (skip > 0) {
            // Do not expose a partial disclosure glyph.
            skip = 0;
            visible_marker = "";
        }
    }
    if (chasen.text.displayWidth(visible_marker) > available - indent_columns) visible_marker = "";
    const prefix_columns = @min(indent_columns + chasen.text.displayWidth(visible_marker), available);
    const name_width = available - prefix_columns;
    const name_window = try manifest.displayWindowAlloc(allocator, node.name, skip, name_width);
    const indent = try allocator.alloc(u8, indent_columns);
    @memset(indent, ' ');
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ indent, visible_marker, name_window.text() });
}

test "repository page zero state deinitializes and activation is lazy" {
    var state: RepositoryPageState = .{};
    state.deinit(std.testing.allocator);
    state = .{};
    state.activate(3, .{ .device = 1, .inode = 2 });
    try std.testing.expect(state.initialized);
    try std.testing.expect(state.needs_revalidation);
    try std.testing.expectEqual(@as(u64, 3), state.repo_epoch);
}

test "repository page navigation keeps sticky file selection on directory" {
    var document = try manifest.parseOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "a/one.zig\x00b.zig\x00"));
    const tree = try repository_tree.Tree.build(std.testing.allocator, &document);
    var state: RepositoryPageState = .{ .bundle = .{ .document = document, .tree = tree }, .load_state = .loaded };
    defer state.deinit(std.testing.allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.viewer.tree_cursor = 1;
    _ = state.applyNavigation(std.testing.allocator, .toggle_directory, .{ .width = 60, .height = 11 });
    try std.testing.expectEqualStrings("a/one.zig", state.selected_path.?);
    state.viewer.tree_cursor = 0;
    _ = state.applyNavigation(std.testing.allocator, .toggle_directory, .{ .width = 60, .height = 11 });
    try std.testing.expectEqualStrings("a/one.zig", state.selected_path.?);
}

test "repository manifest replacement refreshes active file search indices" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("old.zig\x00other.zig\x00"),
        .load_state = .loaded,
        .file_search = .{ .mode = true },
    };
    defer state.deinit(allocator);
    try state.file_search.input.insertSlice("old");
    repository_navigation.refreshFileSearch(&state.file_search, &state.bundle.?.tree, .all);
    try std.testing.expectEqual(@as(usize, 1), state.file_search.len);

    var incoming = try bundleForTest("new.zig\x00");
    errdefer incoming.deinit(allocator);
    try state.replaceBundle(allocator, &incoming);
    try std.testing.expectEqual(@as(usize, 0), state.file_search.len);
    try std.testing.expect(state.file_search.no_match);
}

test "repository All replacement keeps pre-filter hidden-selection cursor fallback" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("dir/selected.zig\x00root.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("dir/selected.zig", .all);
    try std.testing.expect(state.bundle.?.tree.toggleVisible(0));
    state.viewer.tree_cursor = 1;

    var incoming = try bundleForTest("dir/selected.zig\x00root.zig\x00");
    errdefer incoming.deinit(allocator);
    try state.replaceBundle(allocator, &incoming);
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.tree_cursor);
    try std.testing.expectEqualStrings("dir/selected.zig", state.selected_path.?);
}

fn bundleForTest(bytes: []const u8) !Bundle {
    var document = try manifest.parseOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
    errdefer document.deinit(std.testing.allocator);
    return .{ .tree = try repository_tree.Tree.build(std.testing.allocator, &document), .document = document };
}

fn applyBundleStatusForTest(bundle: *Bundle, bytes: []const u8) !void {
    var index = try repository_change_index.parseOwned(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, bytes),
    );
    defer index.deinit(std.testing.allocator);
    _ = bundle.tree.applyChangeIndex(&index);
    bundle.status_fingerprint = index.fingerprint;
    bundle.status_available = true;
}

test "repository changed filter retains changed selection without document reload" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("changed.zig\x00clean.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 3,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M changed.zig\x00");
    state.selected_path = state.bundle.?.tree.filePath("changed.zig", .all);
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "changed.zig"),
        .manifest_revision = 3,
        .value = .{ .inert = .binary },
    };

    try std.testing.expect(!state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }));
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);
    try std.testing.expectEqualStrings("changed.zig", state.selected_path.?);
    try std.testing.expectEqualStrings("changed.zig", state.all_selection_anchor.?);
    try std.testing.expect(state.displayed_document != null);
    try std.testing.expect(!state.needs_document_revalidation);

    try std.testing.expect(!state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }));
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expectEqualStrings("changed.zig", state.selected_path.?);
    try std.testing.expect(state.all_selection_anchor == null);
    try std.testing.expect(state.displayed_document != null);
}

test "repository changed filter falls back and restores owned All selection" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("changed.zig\x00clean.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 3,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M changed.zig\x00");
    state.selected_path = state.bundle.?.tree.filePath("clean.zig", .all);
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "clean.zig"),
        .manifest_revision = 3,
        .value = .{ .inert = .binary },
    };

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }));
    try std.testing.expectEqualStrings("changed.zig", state.selected_path.?);
    try std.testing.expectEqualStrings("clean.zig", state.all_selection_anchor.?);
    try std.testing.expect(state.displayed_document == null);
    try std.testing.expect(state.needs_document_revalidation);

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }));
    try std.testing.expectEqualStrings("clean.zig", state.selected_path.?);
    try std.testing.expect(state.all_selection_anchor == null);
}

test "repository changed navigation and mouse use only filtered visible rows" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("a-change.zig\x00b-clean.zig\x00c-change.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M a-change.zig\x00 M c-change.zig\x00");
    state.selected_path = state.bundle.?.tree.filePath("a-change.zig", .all);
    const size = chasen.Size{ .width = 80, .height = 10 };
    _ = state.applyNavigation(allocator, .toggle_changed_filter, size);
    try std.testing.expectEqual(@as(usize, 2), state.bundle.?.tree.visible_len);

    _ = state.applyNavigation(allocator, .move_down, size);
    try std.testing.expectEqualStrings("c-change.zig", state.selected_path.?);
    const mouse_msg = state.mouseToMsg(.{ .col = 1, .row = 1 }, .left, size) orelse return error.ExpectedFilteredMouseRow;
    _ = state.applyNavigation(allocator, mouse_msg, size);
    try std.testing.expectEqualStrings("a-change.zig", state.selected_path.?);
    _ = state.applyNavigation(allocator, .tree_last, size);
    try std.testing.expectEqualStrings("c-change.zig", state.selected_path.?);
    state.viewer.tree_cursor = 99;
    state.viewer.tree_vertical_scroll = 99;
    state.clampForBodySize(.{ .width = 24, .height = 2 });
    try std.testing.expect(state.viewer.tree_cursor < state.bundle.?.tree.visible_len);
    try std.testing.expect(state.viewer.tree_vertical_scroll < state.bundle.?.tree.visible_len);
}

test "repository changed no-match clears document and All restores anchor once" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("clean.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 3,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, "");
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "clean.zig"),
        .manifest_revision = 3,
        .value = .{ .inert = .binary },
    };

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }));
    try std.testing.expect(state.selected_path == null);
    try std.testing.expect(state.displayed_document == null);
    try std.testing.expect(!state.needs_document_revalidation);
    try std.testing.expectEqualStrings("clean.zig", state.all_selection_anchor.?);

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }));
    try std.testing.expectEqualStrings("clean.zig", state.selected_path.?);
    try std.testing.expect(state.needs_document_revalidation);
    const generation = state.document_generation;
    try std.testing.expect(!state.applyNavigation(allocator, .tree_first, .{ .width = 80, .height = 10 }));
    try std.testing.expectEqual(generation, state.document_generation);
}

test "repository changed filter allocation failure leaves mode and selection unchanged" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .pending_document_generation = 7,
        .pending_syntax_generation = 8,
        .pending_change_map_generation = 9,
        .needs_syntax_request = true,
        .needs_change_map_request = true,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expect(!state.applyNavigation(failing.allocator(), .toggle_changed_filter, .{ .width = 80, .height = 10 }));
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expectEqualStrings("main.zig", state.selected_path.?);
    try std.testing.expect(state.all_selection_anchor == null);
    try std.testing.expectEqual(@as(?u64, 7), state.pending_document_generation);
    try std.testing.expectEqual(@as(?u64, 8), state.pending_syntax_generation);
    try std.testing.expectEqual(@as(?u64, 9), state.pending_change_map_generation);
    try std.testing.expect(state.needs_syntax_request);
    try std.testing.expect(state.needs_change_map_request);
    try std.testing.expectEqualStrings("Could not preserve All selection", state.status.text());
}

test "repository changed filter survives page activation and resets for repository identity" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 1, .inode = 2 };
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("changed.zig\x00clean.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M changed.zig\x00");
    state.selected_path = state.bundle.?.tree.filePath("clean.zig", .all);
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 });

    state.deactivate();
    state.activate(4, identity);
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);
    try std.testing.expectEqualStrings("clean.zig", state.all_selection_anchor.?);

    state.repositoryChanged(allocator, 5, .{ .device = 3, .inode = 4 });
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expect(state.all_selection_anchor == null);
}

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

test "repository status-only completion preserves source and revisions" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("a.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 7,
        .source_revision = 11,
        .displayed_document = .{
            .path = try allocator.dupe(u8, "a.zig"),
            .manifest_revision = 7,
            .source_revision = 11,
            .value = .{ .inert = .unreadable },
        },
    };
    defer state.deinit(allocator);
    state.activate(3, root.capability.identity);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    var request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer request.deinit(allocator);
    const displayed_path_address = @intFromPtr(state.displayed_document.?.path.ptr);
    var finished = ManifestFinished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .status_changed = .{ .loaded = try repository_change_index.parseOwned(
            allocator,
            try allocator.dupe(u8, " M a.zig\x00"),
        ) } },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &finished));
    try std.testing.expectEqual(@as(u64, 7), state.manifest_revision);
    try std.testing.expectEqual(@as(u64, 11), state.source_revision);
    try std.testing.expectEqual(displayed_path_address, @intFromPtr(state.displayed_document.?.path.ptr));
    try std.testing.expect(state.needs_document_revalidation);
    try std.testing.expect(state.wantsDocumentRequest());
    try std.testing.expectEqual(repository_change_index.Kind.modified, state.bundle.?.tree.nodes[0].file_change.?);

    state.needs_revalidation = true;
    var unavailable_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer unavailable_request.deinit(allocator);
    var unavailable = ManifestFinished{
        .identity = unavailable_request.identity,
        .root_identity = unavailable_request.root.identity,
        .generation = unavailable_request.generation,
        .result = .{ .status_changed = .unavailable },
    };
    defer unavailable.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &unavailable));
    try std.testing.expect(state.bundle.?.tree.nodes[0].file_change == null);
    try std.testing.expect(!state.bundle.?.status_available);
    try std.testing.expectEqual(@as(u64, 7), state.manifest_revision);
    try std.testing.expectEqual(displayed_path_address, @intFromPtr(state.displayed_document.?.path.ptr));
    try std.testing.expect(state.needs_document_revalidation);
    try std.testing.expect(state.wantsDocumentRequest());
}

test "repository changed status loss clears projection and All restores anchor" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("a.zig\x00clean.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 7,
        .displayed_document = .{
            .path = try allocator.dupe(u8, "a.zig"),
            .manifest_revision = 7,
            .value = .{ .inert = .binary },
        },
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M a.zig\x00");
    state.activate(3, root.capability.identity);
    state.selected_path = state.bundle.?.tree.filePath("a.zig", .all);
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 });
    try std.testing.expectEqualStrings("a.zig", state.all_selection_anchor.?);

    var request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer request.deinit(allocator);
    var unavailable = ManifestFinished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .status_changed = .unavailable },
    };
    defer unavailable.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &unavailable));
    try std.testing.expect(state.selected_path == null);
    try std.testing.expect(state.displayed_document == null);
    try std.testing.expect(!state.needs_document_revalidation);
    try std.testing.expectEqualStrings("a.zig", state.all_selection_anchor.?);

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }));
    try std.testing.expectEqualStrings("a.zig", state.selected_path.?);
    try std.testing.expect(state.all_selection_anchor == null);
    try std.testing.expect(state.needs_document_revalidation);
}

test "repository changed status refresh moves clears and repopulates selection" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("a.zig\x00b-clean.zig\x00c.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 7,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M a.zig\x00");
    state.activate(3, root.capability.identity);
    state.selected_path = state.bundle.?.tree.filePath("a.zig", .all);
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 });

    const snapshots = [_][]const u8{
        " M c.zig\x00",
        "",
        " M a.zig\x00",
    };
    const expected = [_]?[]const u8{ "c.zig", null, "a.zig" };
    for (snapshots, expected) |status_bytes, expected_path| {
        state.needs_revalidation = true;
        var request = try state.prepareRequest(allocator, root.path, &root.capability);
        defer request.deinit(allocator);
        var finished = ManifestFinished{
            .identity = request.identity,
            .root_identity = request.root.identity,
            .generation = request.generation,
            .result = .{ .status_changed = .{ .loaded = try repository_change_index.parseOwned(
                allocator,
                try allocator.dupe(u8, status_bytes),
            ) } },
        };
        defer finished.deinit(allocator);
        try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &finished));
        if (expected_path) |path|
            try std.testing.expectEqualStrings(path, state.selected_path.?)
        else
            try std.testing.expect(state.selected_path == null);
    }
    try std.testing.expectEqualStrings("a.zig", state.all_selection_anchor.?);
}

test "repository replacement keeps changed mode anchor independent of manifest storage" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("changed.zig\x00clean.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M changed.zig\x00");
    state.selected_path = state.bundle.?.tree.filePath("clean.zig", .all);
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 });

    var incoming = try bundleForTest("a-first.zig\x00changed.zig\x00new.zig\x00");
    errdefer incoming.deinit(allocator);
    try applyBundleStatusForTest(&incoming, " M changed.zig\x00?? new.zig\x00");
    try state.replaceBundle(allocator, &incoming);
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);
    try std.testing.expectEqualStrings("changed.zig", state.selected_path.?);
    try std.testing.expectEqualStrings("clean.zig", state.all_selection_anchor.?);

    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 });
    try std.testing.expectEqualStrings("changed.zig", state.selected_path.?);
}

fn runRepositoryTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
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

test "repository real reload updates status color and selected source" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    var work = try tmp.dir.openDir(io, "repo", .{});
    defer work.close(io);
    try runRepositoryTestGit(io, work, &.{ "git", "init", "--initial-branch=main" });
    try work.writeFile(io, .{ .sub_path = "a.zig", .data = "const value = 1;\n" });
    try runRepositoryTestGit(io, work, &.{ "git", "add", "a.zig" });
    try runRepositoryTestGit(io, work, &.{
        "git",
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "-m",
        "base",
    });
    const root_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(root_path);
    var capability = try root_capability.RootCapability.openCanonical(root_path);
    defer capability.deinit();

    var state: RepositoryPageState = .{};
    defer state.deinit(allocator);
    state.activate(1, capability.identity);
    var initial_request = try state.prepareRequest(allocator, root_path, &capability);
    defer initial_request.deinit(allocator);
    var initial_finished = ManifestFinished{
        .identity = initial_request.identity,
        .root_identity = initial_request.root.identity,
        .generation = initial_request.generation,
        .result = runManifestLoad(
            initial_request.root.dir(),
            initial_request.expected_fingerprint,
            initial_request.expected_status_fingerprint,
            allocator,
            io,
        ),
    };
    defer initial_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &initial_finished));
    try std.testing.expect(state.wantsDocumentRequest());

    var initial_document_request = try state.prepareDocumentRequest(allocator, &capability);
    defer initial_document_request.deinit(allocator);
    var initial_loaded = selected_document.load(initial_document_request.root, initial_document_request.path, allocator, io);
    defer initial_loaded.deinit(allocator);
    var initial_document_finished = DocumentFinished{
        .identity = initial_document_request.identity,
        .root_identity = initial_document_request.root.identity,
        .generation = initial_document_request.generation,
        .manifest_revision = initial_document_request.manifest_revision,
        .path = try allocator.dupe(u8, initial_document_request.path),
        .value = DocumentValue.fromLoaded(allocator, &initial_loaded),
    };
    defer initial_document_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &initial_document_finished));
    try std.testing.expectEqualStrings("const value = 1;\n", state.currentSource().?.bytes);
    const manifest_revision = state.manifest_revision;

    try work.writeFile(io, .{ .sub_path = "a.zig", .data = "const value = 2;\n" });
    state.requestReload(true);
    var reload_request = try state.prepareRequest(allocator, root_path, &capability);
    defer reload_request.deinit(allocator);
    var reload_finished = ManifestFinished{
        .identity = reload_request.identity,
        .root_identity = reload_request.root.identity,
        .generation = reload_request.generation,
        .result = runManifestLoad(
            reload_request.root.dir(),
            reload_request.expected_fingerprint,
            reload_request.expected_status_fingerprint,
            allocator,
            io,
        ),
    };
    defer reload_finished.deinit(allocator);
    try std.testing.expect(reload_finished.result == .status_changed);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &reload_finished));
    try std.testing.expectEqual(manifest_revision, state.manifest_revision);
    try std.testing.expectEqual(repository_change_index.Kind.modified, state.bundle.?.tree.nodes[0].file_change.?);
    try std.testing.expect(state.wantsDocumentRequest());

    var reload_document_request = try state.prepareDocumentRequest(allocator, &capability);
    defer reload_document_request.deinit(allocator);
    var reload_loaded = selected_document.load(reload_document_request.root, reload_document_request.path, allocator, io);
    defer reload_loaded.deinit(allocator);
    var reload_document_finished = DocumentFinished{
        .identity = reload_document_request.identity,
        .root_identity = reload_document_request.root.identity,
        .generation = reload_document_request.generation,
        .manifest_revision = reload_document_request.manifest_revision,
        .path = try allocator.dupe(u8, reload_document_request.path),
        .value = DocumentValue.fromLoaded(allocator, &reload_loaded),
    };
    defer reload_document_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &reload_document_finished));
    try std.testing.expectEqualStrings("const value = 2;\n", state.currentSource().?.bytes);
}

test "repository tree file colors preserve directory and selection priority" {
    const allocator = std.testing.allocator;
    var bundle = try bundleForTest("added.zig\x00modified.zig\x00selected.zig\x00");
    var index = try repository_change_index.parseOwned(allocator, try allocator.dupe(u8, "?? added.zig\x00" ++
        " M modified.zig\x00" ++
        " M selected.zig\x00"));
    defer index.deinit(allocator);
    _ = bundle.tree.applyChangeIndex(&index);
    var state: RepositoryPageState = .{
        .bundle = bundle,
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.nodes[2].path;
    state.viewer.tree_cursor = 2;
    const palette: theme.Palette = .default();
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(60, 6);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);

    try std.testing.expectEqual(palette.color(.diff_added), test_surface.surface.readCell(1, 1).?.style.fg);
    try std.testing.expectEqual(palette.color(.diff_modified), test_surface.surface.readCell(1, 2).?.style.fg);
    try std.testing.expectEqual(palette.color(.prompt), test_surface.surface.readCell(1, 3).?.style.fg);
}

const TestRoot = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    capability: root_capability.RootCapability,

    fn init() !TestRoot {
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

    fn deinit(self: *TestRoot) void {
        self.capability.deinit();
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

const TaskIdentityTestMsg = union(enum) { repository: Msg };

test "repository tasks derive completion root identity from their descriptor" {
    var root_a = try TestRoot.init();
    defer root_a.deinit();
    var root_b = try TestRoot.init();
    defer root_b.deinit();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const expected_identity = root_b.capability.identity;

    const Manifest = ManifestTask(TaskIdentityTestMsg);
    const manifest_task = try allocator.create(Manifest);
    manifest_task.* = .{
        .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
        .generation = 5,
        .root_path = try allocator.dupe(u8, root_a.path),
        .root = try root_b.capability.duplicate(),
        .expected_fingerprint = null,
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

    const Document = DocumentTask(TaskIdentityTestMsg);
    const document_task = try allocator.create(Document);
    document_task.* = .{
        .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
        .generation = 6,
        .manifest_revision = 7,
        .path = try allocator.dupe(u8, "missing.txt"),
        .root = try root_b.capability.duplicate(),
    };
    var document_message = Document.run(document_task, allocator, io);
    defer document_message.repository.deinitUndelivered(allocator);
    switch (document_message.repository) {
        .document_finished => |finished| try std.testing.expect(expected_identity.eql(finished.root_identity)),
        else => return error.ExpectedDocumentCompletion,
    }
}

test "repository document task builds the bounded source model before delivery" {
    var root = try TestRoot.init();
    defer root.deinit();
    try root.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.zig", .data = "first\r\nsecond\n" });
    const allocator = std.testing.allocator;
    const Document = DocumentTask(TaskIdentityTestMsg);
    const task = try allocator.create(Document);
    task.* = .{
        .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
        .generation = 5,
        .manifest_revision = 6,
        .path = try allocator.dupe(u8, "source.zig"),
        .root = try root.capability.duplicate(),
    };
    var message = Document.run(task, allocator, std.testing.io);
    defer message.repository.deinitUndelivered(allocator);
    switch (message.repository) {
        .document_finished => |finished| switch (finished.value) {
            .source => |source| {
                try std.testing.expectEqual(@as(usize, 2), source.rowCount());
                try std.testing.expectEqualStrings("first", source.lineBody(0).?);
                try std.testing.expectEqualStrings("second", source.lineBody(1).?);
            },
            .inert => return error.ExpectedSource,
        },
        else => return error.ExpectedDocumentCompletion,
    }
}

test "repository syntax task is plain-first and accepts only matching source identity" {
    if (!source_syntax_runtime.enabled) return error.SkipZigTest;
    var root = try TestRoot.init();
    defer root.deinit();
    const source_bytes = "const value: usize = 42;\n";
    try root.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = source_bytes });
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = root.capability.identity,
        .manifest_revision = 5,
        .source_revision = 6,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .needs_syntax_request = true,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned = try allocator.dupe(u8, source_bytes);
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "main.zig"),
        .manifest_revision = 5,
        .source_revision = 6,
        .value = .{ .source = try source_document.Document.initOwned(allocator, owned, .init(owned)) },
    };
    try std.testing.expectEqual(@as(usize, 0), state.displayed_document.?.syntax_spans.spans.len);

    var request = try state.prepareSyntaxRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    const Syntax = SyntaxTask(TaskIdentityTestMsg);
    const task = try allocator.create(Syntax);
    task.* = .{
        .identity = request.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .source_revision = request.source_revision,
        .expected_fingerprint = request.expected_fingerprint,
        .path = try allocator.dupe(u8, request.path),
        .root = try request.root.duplicate(),
    };
    var message = Syntax.run(task, allocator, std.testing.io);
    defer message.repository.deinitUndelivered(allocator);
    switch (message.repository) {
        .syntax_finished => |*finished| {
            try std.testing.expectEqual(ApplyOutcome.changed, state.applySyntaxFinished(allocator, finished));
            try std.testing.expect(state.pending_syntax_generation == null);
        },
        else => return error.ExpectedSyntaxCompletion,
    }

    var stale = SyntaxFinished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .source_revision = request.source_revision,
        .path = try allocator.dupe(u8, request.path),
        .fingerprint = .init("different"),
        .result = .{ .loaded = .empty() },
    };
    defer stale.deinit(allocator);

    stale.identity.repo_epoch += 1;
    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));
    stale.identity = request.identity;

    stale.identity.activation_id += 1;
    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));
    stale.identity = request.identity;

    stale.manifest_revision += 1;
    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));
    stale.manifest_revision = request.manifest_revision;

    stale.source_revision += 1;
    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));
    stale.source_revision = request.source_revision;

    allocator.free(stale.path);
    stale.path = try allocator.dupe(u8, "other.zig");
    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));
    allocator.free(stale.path);
    stale.path = try allocator.dupe(u8, request.path);

    var other_root = try TestRoot.init();
    defer other_root.deinit();
    stale.root_identity = other_root.capability.identity;
    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));
    stale.root_identity = request.root.identity;

    state.pending_syntax_generation = request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applySyntaxFinished(allocator, &stale));

    var candidates = [_]source_syntax.Candidate{.{
        .line_index = 0,
        .span = .{ .start = 0, .end = 5, .role = .keyword },
    }};
    const undelivered_spans = try source_syntax.build(allocator, state.currentSource().?, &candidates);
    var undelivered = Msg{ .syntax_finished = .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .source_revision = request.source_revision,
        .path = try allocator.dupe(u8, request.path),
        .fingerprint = request.expected_fingerprint,
        .result = .{ .loaded = undelivered_spans },
    } };
    undelivered.deinitUndelivered(allocator);
}

test "repository change decoration accepts only the exact displayed source identity" {
    var root = try TestRoot.init();
    defer root.deinit();
    const allocator = std.testing.allocator;
    const source_bytes = "one\ntwo\n";
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = root.capability.identity,
        .manifest_revision = 5,
        .source_revision = 6,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .needs_change_map_request = true,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned = try allocator.dupe(u8, source_bytes);
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "main.zig"),
        .manifest_revision = 5,
        .source_revision = 6,
        .value = .{ .source = try source_document.Document.initOwned(allocator, owned, .init(owned)) },
        .change_decoration = .eligible,
    };

    var request = try state.prepareChangeMapRequest(allocator, &root.capability, "/tmp");
    defer request.deinit(allocator);
    var finished = ChangeMapFinished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .source_revision = request.source_revision,
        .path = try allocator.dupe(u8, request.path),
        .fingerprint = request.expected_fingerprint,
        .content_line_count = request.expected_content_line_count,
        .result = .{ .loaded = try repository_change_map.allAdded(allocator, 2) },
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyChangeMapFinished(allocator, &finished));
    try std.testing.expectEqual(repository_change_map.Kind.added, state.displayed_document.?.change_decoration.map().?.row(1));

    state.displayed_document.?.change_decoration.deinit(allocator);
    state.displayed_document.?.change_decoration = .eligible;
    state.needs_change_map_request = true;
    var stale_request = try state.prepareChangeMapRequest(allocator, &root.capability, "/tmp");
    defer stale_request.deinit(allocator);
    var stale = ChangeMapFinished{
        .identity = stale_request.identity,
        .root_identity = stale_request.root.identity,
        .generation = stale_request.generation,
        .manifest_revision = stale_request.manifest_revision,
        .source_revision = stale_request.source_revision,
        .path = try allocator.dupe(u8, stale_request.path),
        .fingerprint = stale_request.expected_fingerprint,
        .content_line_count = stale_request.expected_content_line_count,
        .result = .{ .loaded = try repository_change_map.allAdded(allocator, 2) },
    };
    defer stale.deinit(allocator);

    stale.identity.repo_epoch += 1;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    stale.identity = stale_request.identity;

    stale.identity.activation_id += 1;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    stale.identity = stale_request.identity;

    stale.generation += 1;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    stale.generation = stale_request.generation;

    stale.manifest_revision += 1;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    stale.manifest_revision = stale_request.manifest_revision;

    var other_root = try TestRoot.init();
    defer other_root.deinit();
    stale.root_identity = other_root.capability.identity;
    state.pending_change_map_generation = stale_request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    stale.root_identity = stale_request.root.identity;

    stale.source_revision += 1;
    state.pending_change_map_generation = stale_request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    stale.source_revision = stale_request.source_revision;

    allocator.free(stale.path);
    stale.path = try allocator.dupe(u8, "other.zig");
    state.pending_change_map_generation = stale_request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    allocator.free(stale.path);
    stale.path = try allocator.dupe(u8, stale_request.path);

    stale.content_line_count += 1;
    state.pending_change_map_generation = stale_request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    try std.testing.expect(state.needs_document_revalidation);
    stale.content_line_count = stale_request.expected_content_line_count;
    state.needs_document_revalidation = false;

    stale.fingerprint = .init("newer source");
    state.pending_change_map_generation = stale_request.generation;
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyChangeMapFinished(allocator, &stale));
    try std.testing.expect(state.displayed_document.?.change_decoration.isEligible());
    try std.testing.expect(state.needs_document_revalidation);

    var undelivered = Msg{ .change_map_finished = .{
        .identity = stale_request.identity,
        .root_identity = stale_request.root.identity,
        .generation = stale_request.generation,
        .manifest_revision = stale_request.manifest_revision,
        .source_revision = stale_request.source_revision,
        .path = try allocator.dupe(u8, stale_request.path),
        .fingerprint = stale_request.expected_fingerprint,
        .content_line_count = stale_request.expected_content_line_count,
        .result = .{ .loaded = try repository_change_map.allAdded(allocator, 2) },
    } };
    undelivered.deinitUndelivered(allocator);
}

fn expectRepositoryDecorationCompletionOrder(map_first: bool) !void {
    var root = try TestRoot.init();
    defer root.deinit();
    const allocator = std.testing.allocator;
    const source_bytes = "const value = 1;\n";
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = root.capability.identity,
        .manifest_revision = 5,
        .source_revision = 6,
        .syntax_generation = 7,
        .pending_syntax_generation = 7,
        .change_map_generation = 8,
        .pending_change_map_generation = 8,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned = try allocator.dupe(u8, source_bytes);
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "main.zig"),
        .manifest_revision = 5,
        .source_revision = 6,
        .value = .{ .source = try source_document.Document.initOwned(allocator, owned, .init(owned)) },
        .change_decoration = .eligible,
    };
    var candidates = [_]source_syntax.Candidate{.{
        .line_index = 0,
        .span = .{ .start = 0, .end = 5, .role = .keyword },
    }};
    var syntax_finished = SyntaxFinished{
        .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
        .root_identity = root.capability.identity,
        .generation = 7,
        .manifest_revision = 5,
        .source_revision = 6,
        .path = try allocator.dupe(u8, "main.zig"),
        .fingerprint = state.currentSource().?.fingerprint,
        .result = .{ .loaded = try source_syntax.build(allocator, state.currentSource().?, &candidates) },
    };
    defer syntax_finished.deinit(allocator);
    var map_finished = ChangeMapFinished{
        .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 4 },
        .root_identity = root.capability.identity,
        .generation = 8,
        .manifest_revision = 5,
        .source_revision = 6,
        .path = try allocator.dupe(u8, "main.zig"),
        .fingerprint = state.currentSource().?.fingerprint,
        .content_line_count = 1,
        .result = .{ .loaded = try repository_change_map.allAdded(allocator, 1) },
    };
    defer map_finished.deinit(allocator);

    if (map_first) {
        try std.testing.expectEqual(ApplyOutcome.changed, state.applyChangeMapFinished(allocator, &map_finished));
        try std.testing.expectEqual(ApplyOutcome.changed, state.applySyntaxFinished(allocator, &syntax_finished));
    } else {
        try std.testing.expectEqual(ApplyOutcome.changed, state.applySyntaxFinished(allocator, &syntax_finished));
        try std.testing.expectEqual(ApplyOutcome.changed, state.applyChangeMapFinished(allocator, &map_finished));
    }
    try std.testing.expectEqual(repository_change_map.Kind.added, state.displayed_document.?.change_decoration.map().?.row(0));
    try std.testing.expectEqual(@as(usize, 1), state.displayed_document.?.syntax_spans.spans.len);
}

test "repository syntax and change map completions are order independent" {
    try expectRepositoryDecorationCompletionOrder(true);
    try expectRepositoryDecorationCompletionOrder(false);
}

test "repository page accepts active and inactive matching manifest completions" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{};
    defer state.deinit(std.testing.allocator);
    state.activate(7, root.capability.identity);
    var request = try state.prepareRequest(std.testing.allocator, root.path, &root.capability);
    defer request.deinit(std.testing.allocator);
    var finished = ManifestFinished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .loaded = try bundleForTest("src/main.zig\x00") },
    };
    defer finished.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(std.testing.allocator, &finished));
    try std.testing.expectEqualStrings("src/main.zig", state.selected_path.?);
    try std.testing.expect(state.freshness == .fresh);

    state.needs_revalidation = true;
    var unchanged_request = try state.prepareRequest(std.testing.allocator, root.path, &root.capability);
    defer unchanged_request.deinit(std.testing.allocator);
    const retained_bundle = &state.bundle.?;
    var unchanged = ManifestFinished{
        .identity = unchanged_request.identity,
        .root_identity = unchanged_request.root.identity,
        .generation = unchanged_request.generation,
        .result = .{ .unchanged = retained_bundle.document.fingerprint },
    };
    defer unchanged.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.unchanged, state.applyFinished(std.testing.allocator, &unchanged));
    try std.testing.expectEqual(retained_bundle, &state.bundle.?);

    state.needs_revalidation = true;
    var inactive_request = try state.prepareRequest(std.testing.allocator, root.path, &root.capability);
    defer inactive_request.deinit(std.testing.allocator);
    state.deactivate();
    var inactive = ManifestFinished{
        .identity = inactive_request.identity,
        .root_identity = inactive_request.root.identity,
        .generation = inactive_request.generation,
        .result = .{ .loaded = try bundleForTest("README.md\x00src/main.zig\x00") },
    };
    defer inactive.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(std.testing.allocator, &inactive));
    try std.testing.expect(state.bundle != null);
    try std.testing.expect(state.freshness == .validating);
    state.activate(7, root.capability.identity);
    try std.testing.expect(state.needs_revalidation);
}

test "repository page rejects stale completion and undelivered message frees payload" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{};
    defer state.deinit(std.testing.allocator);
    state.activate(2, root.capability.identity);
    var request = try state.prepareRequest(std.testing.allocator, root.path, &root.capability);
    defer request.deinit(std.testing.allocator);
    var stale = ManifestFinished{
        .identity = .{ .origin = .repository, .repo_epoch = 1, .activation_id = request.identity.activation_id },
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .loaded = try bundleForTest("old.zig\x00") },
    };
    defer stale.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(std.testing.allocator, &stale));
    try std.testing.expect(state.bundle == null);

    var undelivered = Msg{ .manifest_finished = .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .result = .{ .loaded = try bundleForTest("owned.zig\x00") },
    } };
    undelivered.deinitUndelivered(std.testing.allocator);
}

test "repository page rejects matching generation with wrong root identity" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{};
    defer state.deinit(std.testing.allocator);
    state.activate(2, root.capability.identity);
    var request = try state.prepareRequest(std.testing.allocator, root.path, &root.capability);
    defer request.deinit(std.testing.allocator);
    var finished = ManifestFinished{
        .identity = request.identity,
        .root_identity = .{ .device = request.root.identity.device, .inode = request.root.identity.inode +% 1 },
        .generation = request.generation,
        .result = .{ .loaded = try bundleForTest("wrong.zig\x00") },
    };
    defer finished.deinit(std.testing.allocator);

    try std.testing.expectEqual(ApplyOutcome.failed, state.applyFinished(std.testing.allocator, &finished));
    try std.testing.expect(state.bundle == null);
    try std.testing.expectEqual(@as(u64, 0), state.manifest_revision);
    try std.testing.expect(!state.needs_document_revalidation);
}

test "repository page accepts selected document and renders plain source" {
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{};
    defer state.deinit(std.testing.allocator);
    state.activate(4, root.capability.identity);
    var manifest_request = try state.prepareRequest(std.testing.allocator, root.path, &root.capability);
    defer manifest_request.deinit(std.testing.allocator);
    var manifest_finished = ManifestFinished{
        .identity = manifest_request.identity,
        .root_identity = manifest_request.root.identity,
        .generation = manifest_request.generation,
        .result = .{ .loaded = try bundleForTest("src/main.zig\x00") },
    };
    defer manifest_finished.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(std.testing.allocator, &manifest_finished));
    try std.testing.expect(state.wantsDocumentRequest());

    var request = try state.prepareDocumentRequest(std.testing.allocator, &root.capability);
    defer request.deinit(std.testing.allocator);
    const bytes = try std.testing.allocator.dupe(u8, "const value = 1;\n");
    var finished = DocumentFinished{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .path = try std.testing.allocator.dupe(u8, request.path),
        .value = .{ .source = try source_document.Document.initOwned(
            std.testing.allocator,
            bytes,
            content_fingerprint.Fingerprint.init(bytes),
        ) },
    };
    defer finished.deinit(std.testing.allocator);
    state.viewer.source_cursor = 20;
    state.viewer.source_vertical_scroll = 10;
    state.viewer.source_horizontal_scroll = 30;
    try state.source_search.query.insertSlice("old-query");
    state.source_search.mode = true;
    state.source_search.match = .{ .line = 1, .start = 0, .end = 1 };
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(std.testing.allocator, &finished));
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_horizontal_scroll);
    try std.testing.expectEqual(@as(usize, 0), state.source_search.query.len);
    try std.testing.expect(!state.source_search.mode);
    try std.testing.expect(state.source_search.match == null);
    try std.testing.expectEqual(source_syntax_runtime.enabled, state.needs_syntax_request);
    try std.testing.expectEqual(source_syntax_runtime.enabled, state.wantsSyntaxRequest());
    if (!source_syntax_runtime.enabled) {
        try std.testing.expectError(
            error.SyntaxProviderDisabled,
            state.prepareSyntaxRequest(std.testing.allocator, &root.capability),
        );
    }

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(60, 10);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const snapshot = try test_surface.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "const value = 1;") != null);
}

test "repository syntax start failures preserve retryable source intent" {
    if (!source_syntax_runtime.enabled) return error.SkipZigTest;
    var root = try TestRoot.init();
    defer root.deinit();
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "const value = 1;\n");
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = root.capability.identity,
        .manifest_revision = 5,
        .source_revision = 6,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .needs_syntax_request = true,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.displayed_document = .{
        .path = try allocator.dupe(u8, "main.zig"),
        .manifest_revision = 5,
        .source_revision = 6,
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };

    var path_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, state.prepareSyntaxRequest(path_failing.allocator(), &root.capability));
    state.markSyntaxRequestPreparationFailed();
    try std.testing.expect(state.wantsSyntaxRequest());

    var invalid_root = root_capability.RootCapability{
        .handle = -1,
        .identity = root.capability.identity,
    };
    try std.testing.expectError(error.InvalidRootCapability, state.prepareSyntaxRequest(allocator, &invalid_root));
    state.markSyntaxRequestPreparationFailed();
    try std.testing.expect(state.wantsSyntaxRequest());

    // Both task allocation failure and runtime spawn rejection terminate through
    // rejectSyntaxSpawn; the still-owned request is released by its caller.
    var allocation_request = try state.prepareSyntaxRequest(allocator, &root.capability);
    defer allocation_request.deinit(allocator);
    state.rejectSyntaxSpawn(allocation_request.generation);
    try std.testing.expect(state.wantsSyntaxRequest());

    var retry = try state.prepareSyntaxRequest(allocator, &root.capability);
    defer retry.deinit(allocator);
    var finished = SyntaxFinished{
        .identity = retry.identity,
        .root_identity = retry.root.identity,
        .generation = retry.generation,
        .manifest_revision = retry.manifest_revision,
        .source_revision = retry.source_revision,
        .path = try allocator.dupe(u8, retry.path),
        .fingerprint = retry.expected_fingerprint,
        .result = .{ .loaded = .empty() },
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applySyntaxFinished(allocator, &finished));
    try std.testing.expect(!state.wantsSyntaxRequest());
}

test "repository page owns source focus navigation search and mouse geometry" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("src/main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 3,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const bytes = try allocator.dupe(u8, "first\nneedle here\nthird\nfourth\n");
    state.displayed_document = .{
        .path = try allocator.dupe(u8, state.selected_path.?),
        .manifest_revision = state.manifest_revision,
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };

    const size = chasen.Size{ .width = 60, .height = 6 };
    _ = state.applyNavigation(allocator, .toggle_focus, size);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    _ = state.applyNavigation(allocator, .move_down, size);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
    _ = state.applyNavigation(allocator, .source_last, size);
    try std.testing.expectEqual(@as(usize, 3), state.viewer.source_cursor);
    _ = state.applyNavigation(allocator, .source_first, size);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_cursor);

    _ = state.applyNavigation(allocator, .enter_source_search, size);
    for ("needle") |byte| _ = state.applyNavigation(allocator, .{ .source_search_insert = byte }, size);
    _ = state.applyNavigation(allocator, .submit_source_search, size);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
    try std.testing.expect(state.source_search.match != null);

    const layout = bodyLayout(size);
    try std.testing.expectEqual(Msg.focus_source, state.mouseToMsg(.{ .col = layout.tree_width + 1, .row = 1 }, .left, size).?);
    try std.testing.expectEqual(Msg{ .mouse_source_row = 0 }, state.mouseToMsg(.{ .col = layout.tree_width + 1, .row = 2 }, .left, size).?);
    try std.testing.expectEqual(Msg.mouse_source_wheel_down, state.mouseToMsg(.{ .col = layout.tree_width + 1, .row = 2 }, .wheel_down, size).?);

    state.viewer.focus = .source;
    state.viewer.source_cursor = 2;
    _ = state.applyNavigation(allocator, .wheel_down, size);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 2), state.viewer.source_cursor);

    state.viewer.source_cursor = 99;
    state.viewer.source_vertical_scroll = 99;
    state.viewer.source_horizontal_scroll = 99;
    state.clampForBodySize(size);
    try std.testing.expectEqual(@as(usize, 3), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.source_horizontal_scroll);
}

test "repository source completion rejects stale identity and frees undelivered payload" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .repo_epoch = 4,
        .activation_id = 5,
        .root_identity = .{ .device = 6, .inode = 7 },
        .manifest_revision = 8,
        .document_generation = 9,
        .pending_document_generation = 9,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    try state.source_search.query.insertSlice("retained-on-stale");

    const stale_bytes = try allocator.dupe(u8, "stale\n");
    var stale = DocumentFinished{
        .identity = .{ .origin = .repository, .repo_epoch = 3, .activation_id = 5 },
        .root_identity = state.root_identity.?,
        .generation = 9,
        .manifest_revision = 8,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .source = try source_document.Document.initOwned(allocator, stale_bytes, .init(stale_bytes)) },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale));
    try std.testing.expect(state.displayed_document == null);
    try std.testing.expectEqualStrings("retained-on-stale", state.source_search.query.slice());

    const owned_bytes = try allocator.dupe(u8, "owned\n");
    var undelivered = Msg{ .document_finished = .{
        .identity = .{ .origin = .repository, .repo_epoch = 4, .activation_id = 5 },
        .root_identity = state.root_identity.?,
        .generation = 9,
        .manifest_revision = 8,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .source = try source_document.Document.initOwned(allocator, owned_bytes, .init(owned_bytes)) },
    } };
    undelivered.deinitUndelivered(allocator);

    const matching_bytes = try allocator.dupe(u8, "retained-on-stale\n");
    var matching = DocumentFinished{
        .identity = .{ .origin = .repository, .repo_epoch = 4, .activation_id = 5 },
        .root_identity = state.root_identity.?,
        .generation = 9,
        .manifest_revision = 8,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .source = try source_document.Document.initOwned(allocator, matching_bytes, .init(matching_bytes)) },
    };
    defer matching.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &matching));
    try std.testing.expectEqual(@as(usize, 0), state.source_search.query.len);

    state.pending_document_generation = 10;
    state.rejectDocumentSpawn(10);
    try std.testing.expect(state.pending_document_generation == null);
    try std.testing.expectEqualStrings("Could not start selected file task", state.status.text());
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

test "repository page renders tree and selected-document loading checkpoint" {
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("README.md\x00src/main.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(std.testing.allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(60, 10);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const snapshot = try test_surface.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Repository files") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Loading selected file") != null);
    const non_selected_file = test_surface.surface.readCell(7, 3) orelse return error.ExpectedFileCell;
    try std.testing.expectEqual(theme.Palette.default().color(.foreground), non_selected_file.style.fg);
}

test "repository changed view distinguishes loading unavailable and no-match states" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .file_visibility = .changed,
        .freshness = .validating,
    };
    defer state.deinit(allocator);
    _ = state.rebuildTreeProjection(null, false, 0);

    {
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(120, 8);
        defer test_surface.deinit();
        try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Repository files [changed]") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Loading changed files...") != null);
    }

    state.freshness = .fresh;
    {
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(180, 8);
        defer test_surface.deinit();
        try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Changed-file status unavailable; press r to retry") != null);
    }

    try applyBundleStatusForTest(&state.bundle.?, "");
    _ = state.rebuildTreeProjection(null, false, 0);
    {
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(120, 8);
        defer test_surface.deinit();
        try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "No changed files") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "No file selected") != null);
    }

    // At the minimum split width and two rows the full prose is clipped, but
    // each state still exposes a distinct leading label instead of falling
    // through to an empty All projection.
    const narrow_states = [_]struct { available: bool, freshness: @TypeOf(state.freshness), label: []const u8 }{
        .{ .available = false, .freshness = .validating, .label = "Loading" },
        .{ .available = false, .freshness = .fresh, .label = "Changed-" },
        .{ .available = true, .freshness = .fresh, .label = "No changed" },
    };
    for (narrow_states) |expected| {
        state.bundle.?.status_available = expected.available;
        state.freshness = expected.freshness;
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(24, 2);
        defer test_surface.deinit();
        try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, expected.label) != null);
    }
}

test "repository page layout and mouse mapping share tree geometry" {
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("dir/file.zig\x00root.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(std.testing.allocator);

    const wide = chasen.Size{ .width = 60, .height = 10 };
    const wide_layout = bodyLayout(wide);
    try std.testing.expectEqual(@as(u16, 20), wide_layout.tree_width);
    try std.testing.expectEqual(Msg.focus_tree, state.mouseToMsg(.{ .col = 1, .row = 0 }, .left, wide).?);
    try std.testing.expect(state.mouseToMsg(.{ .col = 20, .row = 1 }, .left, wide) == null);
    try std.testing.expectEqual(Msg{ .mouse_toggle_row = 0 }, state.mouseToMsg(.{ .col = 1, .row = 1 }, .left, wide).?);
    try std.testing.expectEqual(Msg{ .mouse_row = 1 }, state.mouseToMsg(.{ .col = 1, .row = 2 }, .left, wide).?);
    try std.testing.expectEqual(Msg.wheel_down, state.mouseToMsg(.{ .col = 1, .row = 0 }, .wheel_down, wide).?);

    const narrow = chasen.Size{ .width = 20, .height = 6 };
    try std.testing.expectEqual(narrow.width, bodyLayout(narrow).tree_width);
    try std.testing.expectEqual(Msg{ .mouse_row = 1 }, state.mouseToMsg(.{ .col = 19, .row = 2 }, .left, narrow).?);
}

test "repository page owns reload state transitions" {
    var state: RepositoryPageState = .{};
    state.activate(1, null);
    state.requestReload(false);
    try std.testing.expectEqual(LoadState.no_repository, state.load_state);
    try std.testing.expect(!state.needs_revalidation);
    try std.testing.expectEqualStrings("Repository required", state.status.text());

    state.requestReload(true);
    try std.testing.expect(state.needs_revalidation);
    state.markRequestPreparationFailed(error.OutOfMemory);
    try std.testing.expectEqual(LoadState.failed, state.load_state);
    try std.testing.expect(std.mem.indexOf(u8, state.status.text(), "OutOfMemory") != null);
}

test "repository page row rendering is bounded for multiple maximum names" {
    const raw = try std.testing.allocator.alloc(u8, manifest.max_path_bytes);
    defer std.testing.allocator.free(raw);
    @memset(raw, 0x01);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..4) |_| {
        const text = try treeRowTextAlloc(arena.allocator(), .{
            .kind = .file,
            .parent = null,
            .path = raw,
            .name = raw,
            .depth = 100,
        }, 100, 20);
        try std.testing.expect(text.len <= 20 * 4 + 8);
        try std.testing.expect(chasen.text.displayWidth(text) <= 20);
    }
}
