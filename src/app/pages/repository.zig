const std = @import("std");
const chasen = @import("chasen");
const draw = @import("draw");
const theme = @import("theme");
const app_state = @import("../state.zig");
const content_fingerprint = @import("../../content_fingerprint.zig");
const page = @import("../page.zig");
const page_link = @import("../page_link.zig");
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
const repository_file_search_focus = @import("repository/file_search_focus.zig");
const repository_incoming = @import("repository/incoming.zig");
const repository_layout = @import("repository/layout.zig");
const repository_model = @import("repository/model.zig");
const repository_navigation = @import("repository/navigation.zig");
const repository_selection = @import("repository/selection.zig");
const repository_source_geometry = @import("repository/source_geometry.zig");
const repository_tree_projection = @import("repository/tree_projection.zig");
const repository_view = @import("repository/view.zig");
const text_projection = @import("../../text/projection.zig");

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
    /// Whether the visible bytes are also usable as current interaction
    /// authority. A retained last-good document remains renderable while
    /// revalidation is pending or has terminally failed, but only an exact
    /// accepted document completion may restore `.accepted`.
    pub const Authority = enum {
        accepted,
        revalidation_required,
    };

    path: []u8,
    manifest_revision: u64,
    source_revision: u64 = 0,
    authority: Authority,
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
    mouse_source_press: BodyPoint,
    mouse_source_drag: ?BodyPoint,
    mouse_source_release: ?BodyPoint,
    cancel_source_selection,
    mouse_source_wheel_up,
    mouse_source_wheel_down,
    focus_tree,
    focus_source,
    toggle_focus,
    tree_first,
    tree_last,
    toggle_tree_visibility,
    decrease_tree_width,
    increase_tree_width,
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

/// Repository remains the semantic owner of selected source bytes. Commands
/// transfer only separately owned shell effects; App never reconstructs text
/// from page state or source coordinates.
pub const Command = union(enum) {
    copy_source_selection: []u8,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .copy_source_selection => |text| allocator.free(text),
        }
        self.* = undefined;
    }
};

pub const RepositoryUpdate = struct {
    selected_path_changed: bool = false,
    command: ?Command = null,

    pub fn deinit(self: *RepositoryUpdate, allocator: std.mem.Allocator) void {
        if (self.command) |*command| command.deinit(allocator);
        self.* = .{};
    }

    pub fn takeCommand(self: *RepositoryUpdate) ?Command {
        const command = self.command;
        self.command = null;
        return command;
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
    tree_visible: bool,
    source_col: u16,
    source_width: u16,
    /// Rows 0-1 intentionally mirror Review's spacer before the row-2 Files
    /// heading. Projected root/tree navigation begins at row 3.
    header_rows: u16 = 3,

    pub fn treeRows(self: BodyLayout, body_height: u16) u16 {
        return body_height -| self.header_rows;
    }

    pub fn treeBodyRow(self: BodyLayout, point: BodyPoint) ?usize {
        if (!self.tree_visible or point.col >= self.tree_width or point.row < self.header_rows) return null;
        return point.row - self.header_rows;
    }
};

pub fn bodyLayout(size: chasen.Size, preferred_tree_width: ?u16, tree_hidden: bool) BodyLayout {
    if (tree_hidden) return .{
        .tree_width = 0,
        .tree_visible = false,
        .source_col = 0,
        .source_width = size.width,
    };
    const tree_width = repository_layout.treeWidth(size.width, preferred_tree_width);
    const source_col = if (tree_width < size.width) tree_width + 1 else size.width;
    return .{
        .tree_width = tree_width,
        .tree_visible = true,
        .source_col = source_col,
        .source_width = size.width -| source_col,
    };
}

/// Converts shell-body coordinates to source-pane-local coordinates. A point
/// in the tree, separator, or outside the body is intentionally `null`, which
/// lets a live drag leave the pane without mutating its logical endpoint.
pub fn sourceGesturePoint(point: ?BodyPoint, size: chasen.Size, preferred_tree_width: ?u16, tree_hidden: bool) ?BodyPoint {
    const body_point = point orelse return null;
    const layout = bodyLayout(size, preferred_tree_width, tree_hidden);
    if (body_point.col < layout.source_col or body_point.col >= size.width) return null;
    return .{ .col = body_point.col - layout.source_col, .row = body_point.row };
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
    /// Basis and generation of the request currently named by
    /// `pending_document_generation`. Its path borrows the accepted manifest,
    /// so every selected-path/manifest replacement clears it first.
    pending_document_request: ?repository_file_search_focus.PendingDocumentRequest = null,
    /// One-shot handoff installed by a successful file-search submit. Content
    /// acceptance remains owned by `applyDocumentFinished`; this value only
    /// decides whether that accepted source may move focus.
    file_search_source_focus: repository_file_search_focus.State = .none,
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
    /// Owned contextual navigation request or bounded unavailable terminal.
    /// Activation/deactivation and manual reload retain it; an explicit newer
    /// destination, repository replacement, or deinit releases it once.
    incoming: repository_incoming.State = .none,
    /// Live coordinates borrow `displayed_document`; every owner-replacement
    /// path must cancel this value before freeing source/path storage.
    source_selection: ?repository_selection.DragSelection = null,
    /// Release-frozen source identity, coordinates, and text. Unlike the live
    /// gesture, this owns all storage and never blocks reload or page switches.
    completed_selection: ?repository_selection.CompletedSelection = null,
    file_visibility: repository_tree.Visibility = .all,
    /// Owned raw path captured before entering Changed mode. It is deliberately
    /// independent from manifest generations so background replacement cannot
    /// leave a borrowed selection dangling before the user returns to All.
    all_selection_anchor: ?[]u8 = null,
    /// Page-local root disclosure and typed row projection. The manifest tree
    /// remains root-free and owns only repository-relative entries.
    tree_projection: repository_tree_projection.State = .{},
    viewer: repository_model.ViewerState = .{},
    source_search: repository_model.SourceSearchState = .{},
    file_search: repository_model.FileSearchState = .{},
    status: app_state.StatusMessage = .{},

    fn currentFileSearchFocusBasis(self: *const RepositoryPageState) ?repository_file_search_focus.Basis {
        const root_identity = self.root_identity orelse return null;
        const path = self.selected_path orelse return null;
        return .{
            .repo_epoch = self.repo_epoch,
            .activation_id = self.activation_id,
            .root_identity = root_identity,
            .manifest_revision = self.manifest_revision,
            .path = path,
        };
    }

    /// Close both parts of the pending document owner together. The separate
    /// scalar remains the existing task-admission API; the typed value supplies
    /// the exact basis needed by file-search direct binding.
    fn clearPendingDocumentAuthority(self: *RepositoryPageState) void {
        self.pending_document_generation = null;
        self.pending_document_request = null;
    }

    fn clearPendingDocumentAuthorityIfGeneration(self: *RepositoryPageState, generation: u64) bool {
        if (self.pending_document_generation != generation) return false;
        self.clearPendingDocumentAuthority();
        return true;
    }

    /// Clear borrowed focus/request bases before their selected path or
    /// manifest owner can move or be released.
    fn clearFileSearchDocumentAuthority(self: *RepositoryPageState) void {
        self.file_search_source_focus.clear();
        self.clearPendingDocumentAuthority();
    }

    pub fn deinit(self: *RepositoryPageState, allocator: std.mem.Allocator) void {
        self.clearFileSearchDocumentAuthority();
        self.incoming.deinit(allocator);
        self.cancelSourceSelection();
        self.clearCompletedSelection(allocator);
        if (self.bundle) |*bundle| bundle.deinit(allocator);
        if (self.displayed_document) |*document| document.deinit(allocator);
        if (self.all_selection_anchor) |anchor| allocator.free(anchor);
        self.* = .{};
    }

    pub fn activate(self: *RepositoryPageState, repo_epoch: u64, identity: ?root_capability.Identity) void {
        self.clearFileSearchDocumentAuthority();
        self.initialized = true;
        self.active = true;
        self.activation_id +%= 1;
        if (self.activation_id == 0) self.activation_id = 1;
        if (self.repo_epoch != repo_epoch) self.repo_epoch = repo_epoch;
        self.root_identity = identity;
        self.pending_generation = null;
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.needs_syntax_request = false;
        self.needs_change_map_request = false;
        self.needs_document_revalidation = false;
        self.invalidateDisplayedDocumentAuthority();
        // The activation identity changes even when the repository does not,
        // so old manifest/document generations can no longer complete. Rewind
        // the same destination owner to the manifest authority that can name
        // its next valid successor cycle.
        _ = self.incoming.restartManifestCycle();
        if (identity == null) {
            self.needs_revalidation = false;
            self.freshness = .unavailable;
            self.load_state = .no_repository;
            _ = self.terminalizeIncoming(.request_failed);
            return;
        }
        self.status.clear();
        self.needs_revalidation = true;
        self.freshness = .validating;
    }

    pub fn deactivate(self: *RepositoryPageState) void {
        self.file_search_source_focus.clear();
        self.active = false;
        if (self.bundle != null) self.freshness = .validating;
    }

    pub fn repositoryChanged(
        self: *RepositoryPageState,
        allocator: ?std.mem.Allocator,
        repo_epoch: u64,
        identity: ?root_capability.Identity,
    ) void {
        self.clearFileSearchDocumentAuthority();
        if (self.incoming != .none) {
            const owner = allocator orelse @panic("Repository incoming replacement requires an allocator");
            self.incoming.dismiss(owner);
        }
        self.cancelSourceSelection();
        if (self.completed_selection != null) {
            const owner = allocator orelse @panic("Repository completed-selection replacement requires an allocator");
            self.clearCompletedSelection(owner);
        }
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
        self.tree_projection = .{};
        const retained_tree_width = self.viewer.tree_width;
        const retained_tree_hidden = self.preferredTreeHidden();
        self.viewer = .{
            .focus = if (retained_tree_hidden) .source else .tree,
            .tree_width = retained_tree_width,
            .tree_hidden = retained_tree_hidden,
        };
        self.source_search.clear();
        self.file_search.close();
        self.pending_generation = null;
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

    /// Infallible owner-installation half of the shell's two-phase transition.
    /// Identity-dependent resolution must wait until Repository activation has
    /// installed the current repo epoch/root under the approved commit order.
    pub fn acceptIncoming(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        incoming: *page_link.RepositoryIncoming,
    ) void {
        self.incoming.accept(allocator, incoming);
    }

    pub fn dismissIncoming(self: *RepositoryPageState, allocator: std.mem.Allocator) void {
        self.incoming.dismiss(allocator);
    }

    pub fn incomingIsPending(self: *const RepositoryPageState) bool {
        return self.incoming.isPending();
    }

    pub fn incomingUnavailable(self: *const RepositoryPageState) ?*const page_link.RepositoryUnavailable {
        return self.incoming.unavailableValue();
    }

    /// Export only a resolved, page-owned exact path for synchronous Review
    /// lookup. A pending or unavailable contextual destination wins over any
    /// older retained selection and therefore exports no context.
    pub fn reviewTarget(self: *const RepositoryPageState) page_link.RepositoryReviewTarget {
        if (self.incoming != .none) return .no_context;
        const path = self.selected_path orelse return .no_context;
        const identity = self.root_identity orelse return .no_context;
        return .{ .location = .{
            .repo_epoch = self.repo_epoch,
            .root_identity = identity,
            .path = path,
        } };
    }

    pub fn terminalizeIncoming(self: *RepositoryPageState, reason: page_link.RepositoryUnavailableReason) bool {
        return self.incoming.terminalize(reason);
    }

    /// Continue a newly committed owner only after `activate` establishes the
    /// destination identity. Slice C calls this allocation-free operation
    /// after its owner-move/deactivate/activate sequence; accepted async
    /// manifest completions use the same resolver while inactive or active.
    pub fn resolveIncomingAfterActivation(self: *RepositoryPageState, allocator: std.mem.Allocator) bool {
        std.debug.assert(self.active);
        return self.resolveIncomingManifest(allocator);
    }

    /// Resolve only against the full accepted manifest. Normal Repository
    /// restoration is intentionally not reused because it may choose a nearby
    /// file when the preferred path is absent. An explicit cross-page target
    /// either selects the byte-exact file or becomes unavailable.
    fn resolveIncomingManifest(self: *RepositoryPageState, allocator: std.mem.Allocator) bool {
        const location = if (self.incoming.manifestIntent()) |intent| intent.* else return false;
        const active_root = self.root_identity orelse {
            return self.incoming.terminalize(.request_failed);
        };
        if (location.repo_epoch != self.repo_epoch or !location.root_identity.eql(active_root)) {
            return self.incoming.terminalize(.request_failed);
        }

        const bundle = if (self.bundle) |*owned| owned else return false;
        const exact_path = bundle.tree.filePath(location.path, .all) orelse {
            return self.incoming.terminalize(.path_not_found);
        };
        const node_index = bundle.tree.nodeIndexForPath(exact_path, .all) orelse {
            return self.incoming.terminalize(.request_failed);
        };

        if (self.file_visibility == .changed and bundle.tree.filePath(exact_path, .changed) == null) {
            self.file_visibility = .all;
            if (self.all_selection_anchor) |anchor| allocator.free(anchor);
            self.all_selection_anchor = null;
            bundle.tree.rebuildVisibleFor(.all);
            if (self.file_search.mode) {
                self.refreshFileSearch();
            }
            self.status.set("Review target opened in All files", .{});
        }

        const visible_index = self.tree_projection.revealManifestNode(
            &bundle.tree,
            self.file_visibility,
            node_index,
        ) orelse {
            return self.incoming.terminalize(.request_failed);
        };
        const matching_document = if (self.displayed_document) |*displayed|
            displayed.manifest_revision == self.manifest_revision and std.mem.eql(u8, displayed.path, exact_path)
        else
            false;

        if (!optionalPathEql(self.selected_path, exact_path)) {
            self.clearFileSearchDocumentAuthority();
        }
        self.selected_path = exact_path;
        self.viewer.tree_cursor = visible_index;
        self.clampScroll(0);
        if (!matching_document) {
            self.invalidateSelectedDocument(allocator);
        }
        const advanced = self.incoming.advanceToDocument(self.manifest_revision);
        std.debug.assert(advanced);
        _ = self.resolveIncomingDocument(allocator, null);
        return true;
    }

    /// Consume only the accepted source named by the document-stage owner.
    /// `accepted_generation == null` is the no-task case where Repository
    /// already displayed the exact manifest/path before this transition.
    fn resolveIncomingDocument(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        accepted_generation: ?u64,
    ) bool {
        const pending = if (self.incoming.documentIntent()) |document| document.* else return false;
        const active_root = self.root_identity orelse {
            return self.incoming.terminalize(.request_failed);
        };
        if (pending.location.repo_epoch != self.repo_epoch or
            !pending.location.root_identity.eql(active_root))
        {
            return self.incoming.terminalize(.request_failed);
        }
        if (pending.manifest_revision != self.manifest_revision) return false;
        const selected = self.selected_path orelse return false;
        if (!std.mem.eql(u8, pending.location.path, selected)) return false;
        if (accepted_generation) |generation| {
            if (pending.document_generation != generation) return false;
        } else {
            if (pending.document_generation != null) return false;
            if (self.acceptedCurrentSourceForSelection() == null) return false;
        }

        const displayed = if (self.displayed_document) |*document| document else return false;
        if (displayed.manifest_revision != pending.manifest_revision or
            !std.mem.eql(u8, displayed.path, pending.location.path)) return false;
        switch (displayed.value) {
            .source => |*source| {
                if (pending.location.line) |one_based_line| {
                    const requested: usize = if (one_based_line > 0) @intCast(one_based_line - 1) else 0;
                    const line_index = @min(requested, source.rowCount() - 1);
                    self.viewer.focus = .source;
                    self.viewer.source_cursor = line_index;
                    // The next frame clamps this against the real viewport;
                    // keeping the cursor as the provisional top row makes the
                    // accepted location visible even before that geometry pass.
                    self.viewer.source_vertical_scroll = line_index;
                } else if (accepted_generation != null) {
                    // A newly accepted target opens its source. Reusing an
                    // already displayed path with no line is intentionally a
                    // no-op under the approved same-target UX contract.
                    self.viewer.focus = .source;
                }
                const completed = self.incoming.completeDocument(allocator);
                std.debug.assert(completed);
                return true;
            },
            .inert => return self.incoming.terminalize(.source_unavailable),
        }
    }

    fn applyIncomingManifestResolution(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        outcome: ApplyOutcome,
    ) ApplyOutcome {
        if (!self.resolveIncomingManifest(allocator)) return outcome;
        return switch (outcome) {
            .unchanged => .changed,
            .discarded, .changed, .failed => outcome,
        };
    }

    /// Classify a manifest completion which cannot be accepted by the current
    /// request identity. A contextual destination may remain pending only when
    /// an explicitly named successor can still resolve it: the current task, a
    /// scheduled revalidation, or reactivation of an inactive page. Without
    /// one of those successors, retaining `awaiting_manifest` would create an
    /// unbounded owner, so the destination moves to its request-failed terminal.
    fn manifestOwnerHasSuccessor(self: *const RepositoryPageState) bool {
        const current_task_can_advance = if (self.pending_generation) |pending|
            pending == self.generation
        else
            false;
        const scheduled_successor = self.active and self.root_identity != null and self.needs_revalidation;
        const dormant_successor = !self.active;
        return current_task_can_advance or scheduled_successor or dormant_successor;
    }

    /// A document-stage destination may outlive a rejected completion only
    /// when another explicit authority can still settle it. Inactive state is
    /// a named successor because activation rewinds the owner to manifest
    /// authority. Active state instead requires the exact current selection
    /// basis plus either its bound task or a request the page can start next.
    fn documentOwnerHasSuccessor(
        self: *const RepositoryPageState,
        pending: *const repository_incoming.AwaitingDocument,
    ) bool {
        if (!self.active) return true;

        const root = self.root_identity orelse return false;
        const selected = self.selected_path orelse return false;
        if (pending.location.repo_epoch != self.repo_epoch or
            !pending.location.root_identity.eql(root) or
            pending.manifest_revision != self.manifest_revision or
            !std.mem.eql(u8, pending.location.path, selected))
        {
            return false;
        }

        const current_task_can_advance = if (pending.document_generation) |bound|
            self.document_generation == bound and self.pending_document_generation == bound
        else
            false;
        return current_task_can_advance or self.wantsDocumentRequest();
    }

    /// Apply liveness to the owner which remains after a rejected completion,
    /// not to the completion's stage. A stale document result may coexist with
    /// an awaiting-manifest owner after reload; that owner is retained only if
    /// its own manifest authority names a successor.
    fn terminalizeIncomingOwnerWithoutSuccessor(self: *RepositoryPageState) bool {
        const has_successor = switch (self.incoming) {
            .awaiting_manifest => self.manifestOwnerHasSuccessor(),
            .awaiting_document => |*pending| self.documentOwnerHasSuccessor(pending),
            .none, .unavailable => return false,
        };
        if (has_successor) return false;
        const terminalized = self.terminalizeIncoming(.request_failed);
        std.debug.assert(terminalized);
        return true;
    }

    fn classifyMismatchedManifestFinished(self: *RepositoryPageState) ApplyOutcome {
        return if (self.terminalizeIncomingOwnerWithoutSuccessor()) .failed else .discarded;
    }

    fn classifyMismatchedDocumentFinished(self: *RepositoryPageState) ApplyOutcome {
        return if (self.terminalizeIncomingOwnerWithoutSuccessor()) .failed else .discarded;
    }

    pub fn prepareRequest(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        capability: *const root_capability.RootCapability,
    ) !Request {
        // A manifest attempt supersedes pane-focus handoff immediately, but a
        // descriptor-allocation failure must not revoke the still-valid
        // predecessor document task. Close that pending owner only after all
        // fallible request preparation has succeeded below.
        self.file_search_source_focus.clear();
        self.invalidateDisplayedDocumentAuthority();
        const owned_root = try allocator.dupe(u8, repo_root);
        errdefer allocator.free(owned_root);
        var root = try capability.duplicate();
        errdefer root.deinit();
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.pending_generation = self.generation;
        self.clearPendingDocumentAuthority();
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
        // Request preparation transfers authority away from retained visible
        // bytes before allocation/spawn can fail. Only the matching accepted
        // completion below may restore it.
        self.invalidateDisplayedDocumentAuthority();
        const path = try allocator.dupe(u8, selected);
        errdefer allocator.free(path);
        var root = try capability.duplicate();
        errdefer root.deinit();
        self.document_generation +%= 1;
        if (self.document_generation == 0) self.document_generation = 1;
        self.pending_document_generation = self.document_generation;
        const pending_request: repository_file_search_focus.PendingDocumentRequest = .{
            .basis = .{
                .repo_epoch = self.repo_epoch,
                .activation_id = self.activation_id,
                // Record the descriptor's root, independently from current
                // page authority, so direct binding must prove they agree.
                .root_identity = root.identity,
                .manifest_revision = self.manifest_revision,
                .path = selected,
            },
            .generation = self.document_generation,
        };
        self.pending_document_request = pending_request;
        _ = self.file_search_source_focus.bindPrepared(pending_request);
        self.needs_document_revalidation = false;
        if (self.incoming.documentIntent() != null) {
            const bound = self.incoming.bindDocumentGeneration(
                self.manifest_revision,
                selected,
                self.document_generation,
            );
            std.debug.assert(bound);
        }
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

    /// Task allocation/spawn rejects synchronously after one generation was
    /// prepared. Only that exact generation may close its incoming owner; a
    /// stale rejection must not consume a newer successor.
    pub fn rejectSpawn(self: *RepositoryPageState, generation: u64) void {
        if (self.pending_generation != generation) return;
        self.pending_generation = null;
        self.freshness = .failed;
        if (self.bundle == null) self.load_state = .failed;
        self.status.set("Could not start repository manifest task", .{});
        _ = self.terminalizeIncoming(.request_failed);
    }

    pub fn rejectDocumentSpawn(self: *RepositoryPageState, generation: u64) void {
        if (!self.clearPendingDocumentAuthorityIfGeneration(generation)) return;
        self.invalidateDisplayedDocumentAuthority();
        _ = self.file_search_source_focus.clearGeneration(generation);
        self.status.set("Could not start selected file task", .{});
        const pending = self.incoming.documentIntent() orelse return;
        if (pending.document_generation == generation) {
            _ = self.terminalizeIncoming(.request_failed);
        }
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
        self.clearFileSearchDocumentAuthority();
        self.invalidateDisplayedDocumentAuthority();
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
            _ = self.terminalizeIncoming(.request_failed);
            return;
        }
        // Manual reload invalidates any selected-file generation. Re-resolve
        // the retained exact path against the accepted successor manifest
        // before a new document generation may bind to it.
        _ = self.incoming.restartManifestCycle();
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
        // This attempt has no descriptor, but manual reload may have left the
        // current predecessor task acceptable. Retain the destination while
        // that exact generation can still advance it.
        const predecessor_can_advance = if (self.pending_generation) |pending|
            pending == self.generation
        else
            false;
        if (!predecessor_can_advance) _ = self.terminalizeIncoming(.request_failed);
    }

    pub fn markDocumentRequestPreparationFailed(self: *RepositoryPageState, err: anyerror) void {
        self.file_search_source_focus.clear();
        self.invalidateDisplayedDocumentAuthority();
        self.status.set("Could not prepare selected file: {s}", .{@errorName(err)});
        _ = self.terminalizeIncoming(.request_failed);
    }

    pub fn markDocumentCapabilityUnavailable(self: *RepositoryPageState) void {
        self.file_search_source_focus.clear();
        self.invalidateDisplayedDocumentAuthority();
        // Capability lookup used to be an inert retry edge for ordinary
        // browsing. Only a committed contextual destination converts it into
        // a bounded destination-page terminal.
        if (self.incoming.documentIntent() == null) return;
        self.needs_document_revalidation = false;
        self.status.set("Repository root changed", .{});
        // App orchestration reaches this only after the page committed a
        // destination but the root capability vanished before task creation.
        _ = self.terminalizeIncoming(.request_failed);
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
            return self.classifyMismatchedManifestFinished();
        }
        self.pending_generation = null;
        const expected_root = self.root_identity orelse {
            self.acceptFailure("Repository root changed");
            _ = self.terminalizeIncoming(.request_failed);
            return .failed;
        };
        if (!expected_root.eql(finished.root_identity)) {
            self.acceptFailure("Repository root changed");
            _ = self.terminalizeIncoming(.request_failed);
            return .failed;
        }
        switch (finished.result) {
            .unchanged => {
                const changed_status_message = self.file_visibility == .changed and
                    self.bundle != null and !self.bundle.?.status_available;
                self.freshness = if (self.active) .fresh else .validating;
                self.requireDocumentRevalidation();
                self.status.clear();
                return self.applyIncomingManifestResolution(
                    allocator,
                    if (changed_status_message) .changed else .unchanged,
                );
            },
            .status_changed => |*update| {
                const bundle = if (self.bundle) |*owned| owned else {
                    // A status-only completion is only valid against a retained
                    // manifest. Treat an impossible orphan as optional loss;
                    // its owned payload remains with `finished.deinit`.
                    self.freshness = if (self.active) .fresh else .validating;
                    self.status.clear();
                    return self.applyIncomingManifestResolution(allocator, .unchanged);
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
                    self.requireDocumentRevalidation();
                self.freshness = if (self.active) .fresh else .validating;
                self.status.clear();
                const status_availability_changed = self.file_visibility == .changed and
                    previous_status_available != bundle.status_available;
                const changed_status_message = self.file_visibility == .changed and !bundle.status_available;
                return self.applyIncomingManifestResolution(
                    allocator,
                    if (visible_changed or selection_changed or status_availability_changed or changed_status_message) .changed else .unchanged,
                );
            },
            .loaded => |*incoming| {
                self.replaceBundle(allocator, incoming) catch |err| {
                    self.acceptFailure(@errorName(err));
                    _ = self.terminalizeIncoming(.request_failed);
                    return .failed;
                };
                finished.result = .{ .unchanged = self.bundle.?.document.fingerprint };
                self.manifest_revision +%= 1;
                if (self.manifest_revision == 0) self.manifest_revision = 1;
                self.pending_syntax_generation = null;
                self.pending_change_map_generation = null;
                self.needs_syntax_request = false;
                self.needs_change_map_request = false;
                self.needs_document_revalidation = self.selected_path != null;
                if (self.displayed_document) |*document| document.deinit(allocator);
                self.displayed_document = null;
                self.freshness = if (self.active) .fresh else .validating;
                self.status.clear();
                return self.applyIncomingManifestResolution(allocator, .changed);
            },
            .failed_static => |message| {
                self.acceptFailure(message);
                _ = self.terminalizeIncoming(.request_failed);
                return .failed;
            },
        }
    }

    pub fn applyDocumentFinished(self: *RepositoryPageState, allocator: std.mem.Allocator, finished: *DocumentFinished) ApplyOutcome {
        const completion_owns_pending = finished.identity.origin == .repository and
            finished.identity.repo_epoch == self.repo_epoch and
            finished.identity.activation_id == self.activation_id and
            self.pending_document_generation == finished.generation;
        if (!completion_owns_pending or
            finished.generation != self.document_generation or
            finished.manifest_revision != self.manifest_revision)
        {
            // A delivered completion is the terminal event for the exact task
            // identity it owns even when its accepted manifest basis is now
            // stale. It cannot remain named as a future successor.
            if (completion_owns_pending) {
                _ = self.clearPendingDocumentAuthorityIfGeneration(finished.generation);
                _ = self.file_search_source_focus.clearGeneration(finished.generation);
            }
            return self.classifyMismatchedDocumentFinished();
        }
        const cleared_pending = self.clearPendingDocumentAuthorityIfGeneration(finished.generation);
        std.debug.assert(cleared_pending);
        const expected_root = self.root_identity orelse {
            _ = self.file_search_source_focus.clearGeneration(finished.generation);
            _ = self.terminalizeIncomingOwnerWithoutSuccessor();
            return .failed;
        };
        if (!expected_root.eql(finished.root_identity)) {
            _ = self.file_search_source_focus.clearGeneration(finished.generation);
            self.status.set("Repository root changed", .{});
            _ = self.terminalizeIncomingOwnerWithoutSuccessor();
            return .failed;
        }
        const selected = self.selected_path orelse {
            _ = self.file_search_source_focus.clearGeneration(finished.generation);
            return self.classifyMismatchedDocumentFinished();
        };
        if (!std.mem.eql(u8, selected, finished.path)) {
            _ = self.file_search_source_focus.clearGeneration(finished.generation);
            return self.classifyMismatchedDocumentFinished();
        }

        // The live drag borrows the displayed document and must always end
        // before its storage is replaced. A completed candidate is independent
        // owned state: retain it only when the incoming document proves the
        // same complete semantic content token. Delivery generations and the
        // replacement allocation itself are intentionally irrelevant.
        self.cancelSourceSelection();
        self.reconcileCompletedSelectionForDocument(allocator, finished);
        self.pending_syntax_generation = null;
        self.pending_change_map_generation = null;
        self.source_revision +%= 1;
        if (self.source_revision == 0) self.source_revision = 1;
        if (self.displayed_document) |*previous| previous.deinit(allocator);
        self.displayed_document = .{
            .path = finished.path,
            .manifest_revision = finished.manifest_revision,
            .source_revision = self.source_revision,
            .authority = .accepted,
            .value = finished.value,
            .change_decoration = switch (finished.value) {
                .source => .eligible,
                .inert => .terminal_plain,
            },
        };
        finished.path = &.{};
        finished.value = .{ .inert = .unreadable };
        self.viewer.resetSource();
        self.reconcileNoSourceFocus();
        self.source_search.clear();
        self.needs_syntax_request = source_syntax_runtime.enabled and self.currentSource() != null;
        self.needs_change_map_request = self.currentSource() != null;
        self.status.clear();
        self.resolveFileSearchSourceFocus(finished.generation);
        _ = self.resolveIncomingDocument(allocator, finished.generation);
        // A completion may be valid for the ordinary selected source while an
        // inconsistent contextual owner names a different revision/generation.
        // Keep the accepted source, but never leave that owner unbounded.
        _ = self.terminalizeIncomingOwnerWithoutSuccessor();
        return .changed;
    }

    /// Move focus only after the ordinary document admission path has installed
    /// an accepted source for the exact bound Repository basis. Inert content is
    /// an accepting document terminal but cannot own source focus.
    fn resolveFileSearchSourceFocus(self: *RepositoryPageState, generation: u64) void {
        if (self.currentSource() == null) {
            _ = self.file_search_source_focus.clearGeneration(generation);
            return;
        }
        const basis = self.currentFileSearchFocusBasis() orelse return;
        if (self.file_search_source_focus.consumeAccepted(basis, generation)) {
            self.viewer.focus = .source;
        }
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
            self.requireDocumentRevalidation();
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
        self.clearFileSearchDocumentAuthority();
        self.cancelSourceSelection();
        const previous_selected = self.selected_path;
        const previous_cursor_identity = if (self.bundle) |*previous|
            self.tree_projection.cursorIdentity(&previous.tree, self.viewer.tree_cursor)
        else
            null;
        var selected = if (self.bundle) |*previous|
            try incoming.tree.restoreStateFrom(allocator, &previous.tree, previous_selected)
        else
            incoming.tree.firstFilePath();

        incoming.tree.rebuildVisibleFor(self.file_visibility);
        if (self.file_visibility == .changed) {
            const status_usable = incoming.status_available;
            const retained = if (status_usable and selected != null)
                incoming.tree.filePath(selected.?, .changed)
            else
                null;
            selected = retained orelse if (status_usable)
                incoming.tree.firstFilePathFor(.changed)
            else
                null;
        }
        // Resolve the borrowed predecessor identity before freeing its owner.
        // An invalid predecessor cursor explicitly falls back to the selected
        // incoming file when visible, then to the typed root.
        const next_cursor = if (previous_cursor_identity) |identity|
            self.tree_projection.cursorForIdentity(&incoming.tree, self.file_visibility, identity)
        else if (selected) |path|
            self.projectedCursorForPath(&incoming.tree, path) orelse 0
        else
            0;

        // A newly accepted manifest does not yet provide a complete selected
        // source fingerprint. Slice C therefore cannot prove candidate identity.
        self.clearCompletedSelection(allocator);
        if (self.bundle) |*previous| previous.deinit(allocator);
        self.bundle = incoming.*;
        incoming.* = undefined;
        self.selected_path = selected;
        self.load_state = if (self.bundle.?.document.paths.len == 0) .empty else .loaded;
        self.viewer.tree_cursor = next_cursor;
        if (selected == null) self.reconcileNoSourceFocus();
        if (self.file_search.mode) {
            self.refreshFileSearch();
        }
        self.clampScroll(0);
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
            if (previous != null) self.clearFileSearchDocumentAuthority();
            self.selected_path = null;
            self.viewer.tree_cursor = 0;
            self.viewer.tree_vertical_scroll = 0;
            self.file_search.resetResults();
            return !optionalPathEql(previous, null);
        };
        const tree = &bundle.tree;
        const cursor_identity = self.tree_projection.cursorIdentity(tree, self.viewer.tree_cursor);
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
        if (!optionalPathEql(previous, selected)) {
            self.clearFileSearchDocumentAuthority();
        }
        self.selected_path = selected;

        var selected_cursor: ?usize = null;
        if (selected) |path| {
            selected_cursor = self.projectedCursorForPath(tree, path);
            if (selected_cursor == null and (reveal_preferred or retained == null)) {
                if (tree.nodeIndexForPath(path, self.file_visibility)) |node_index| {
                    if (tree.revealNodeFor(node_index, self.file_visibility) != null) {
                        // Internal lens reconciliation may reveal manifest
                        // ancestors, but it does not override a collapsed root.
                        if (self.tree_projection.root_disclosure == .expanded) {
                            selected_cursor = self.tree_projection.visibleIndexForTarget(
                                tree,
                                .{ .manifest_node = node_index },
                            );
                        }
                    }
                }
            }
        }
        self.viewer.tree_cursor = if (cursor_identity) |identity|
            self.tree_projection.cursorForIdentity(tree, self.file_visibility, identity)
        else
            selected_cursor orelse 0;
        if (selected == null) {
            self.viewer.tree_vertical_scroll = 0;
            self.reconcileNoSourceFocus();
        }
        if (self.file_search.mode) {
            self.refreshFileSearch();
        }
        self.clampScroll(body_height);
        return !optionalPathEql(previous, self.selected_path);
    }

    fn projectedCursorForPath(
        self: *const RepositoryPageState,
        tree: *const repository_tree.Tree,
        path: []const u8,
    ) ?usize {
        const node_index = tree.nodeIndexForPath(path, self.file_visibility) orelse return null;
        return self.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = node_index });
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
    ) RepositoryUpdate {
        var result: RepositoryUpdate = .{};
        var file_search_submitted = false;
        // A contextual destination is subordinate to the user's next
        // destination/navigation command. Dismiss it before that command can
        // mutate retained browser state. Pure presentation/cancel commands do
        // not retarget the browser and therefore retain the owner.
        if (navigationDismissesIncoming(msg)) self.dismissIncoming(allocator);
        // Drag/release are the only continuations of a live mouse owner.
        // Any independent page command becomes an explicit cancel terminal so
        // keyboard navigation/search cannot silently retarget the gesture.
        switch (msg) {
            .mouse_source_drag, .mouse_source_release, .cancel_source_selection => {},
            else => self.cancelSourceSelection(),
        }
        const previous = self.selected_path;
        const layout = bodyLayout(body_size, self.viewer.tree_width, self.viewer.tree_hidden);
        const body_height = layout.treeRows(body_size.height);
        const source = self.currentSource();
        const source_geometry = if (source) |document|
            repository_source_geometry.SourceGeometry.init(.{ .width = layout.source_width, .height = body_size.height }, document, self.viewer.line_numbers)
        else
            null;
        switch (msg) {
            .move_up => switch (self.viewer.focus) {
                .source => if (source) |document| repository_navigation.moveSource(&self.viewer, document, -1, source_geometry.?),
                .tree => if (!self.viewer.tree_hidden) self.moveCursor(-1, body_height),
            },
            .move_down => switch (self.viewer.focus) {
                .source => if (source) |document| repository_navigation.moveSource(&self.viewer, document, 1, source_geometry.?),
                .tree => if (!self.viewer.tree_hidden) self.moveCursor(1, body_height),
            },
            .wheel_up => if (!self.viewer.tree_hidden) {
                self.viewer.focus = .tree;
                self.moveCursor(-1, body_height);
            },
            .wheel_down => if (!self.viewer.tree_hidden) {
                self.viewer.focus = .tree;
                self.moveCursor(1, body_height);
            },
            .page_up => switch (self.viewer.focus) {
                .source => if (source) |document| repository_navigation.pageSource(&self.viewer, document, -1, source_geometry.?),
                .tree => if (!self.viewer.tree_hidden) self.moveCursor(-@as(isize, @intCast(@max(body_height -| 1, 1))), body_height),
            },
            .page_down => switch (self.viewer.focus) {
                .source => if (source) |document| repository_navigation.pageSource(&self.viewer, document, 1, source_geometry.?),
                .tree => if (!self.viewer.tree_hidden) self.moveCursor(@intCast(@max(body_height -| 1, 1)), body_height),
            },
            .toggle_directory => if (!self.viewer.tree_hidden) self.toggleCursor(body_height),
            .scroll_left => switch (self.viewer.focus) {
                .source => if (source) |document| repository_navigation.scrollSourceHorizontal(&self.viewer, document, -8, source_geometry.?),
                .tree => if (!self.viewer.tree_hidden) {
                    self.viewer.tree_horizontal_scroll -|= 4;
                },
            },
            .scroll_right => switch (self.viewer.focus) {
                .source => if (source) |document| repository_navigation.scrollSourceHorizontal(&self.viewer, document, 8, source_geometry.?),
                .tree => if (!self.viewer.tree_hidden) {
                    self.viewer.tree_horizontal_scroll = @min(self.viewer.tree_horizontal_scroll +| 4, manifest.max_path_bytes * 4);
                },
            },
            .mouse_row => |row| {
                self.viewer.focus = .tree;
                self.setCursor(row, body_height, false);
            },
            .mouse_toggle_row => |row| {
                self.viewer.focus = .tree;
                self.setCursor(row, body_height, true);
            },
            .mouse_source_press => |point| self.pressSourceSelection(point, body_size),
            .mouse_source_drag => |point| self.dragSourceSelection(point, body_size),
            .mouse_source_release => |point| result.command = self.releaseSourceSelection(allocator, point, body_size),
            .cancel_source_selection => self.cancelSourceSelection(),
            .mouse_source_wheel_up => if (source) |document| {
                self.viewer.focus = .source;
                repository_navigation.moveSource(&self.viewer, document, -1, source_geometry.?);
            },
            .mouse_source_wheel_down => if (source) |document| {
                self.viewer.focus = .source;
                repository_navigation.moveSource(&self.viewer, document, 1, source_geometry.?);
            },
            .focus_tree => if (!self.viewer.tree_hidden) {
                self.viewer.focus = .tree;
            },
            .focus_source => if (source != null) {
                self.viewer.focus = .source;
            },
            .toggle_focus => if (source != null and !self.viewer.tree_hidden) {
                self.viewer.focus = if (self.viewer.focus == .tree) .source else .tree;
            },
            .toggle_tree_visibility => self.toggleTreeVisibility(body_size),
            .decrease_tree_width => self.adjustTreeWidth(.shrink, body_size),
            .increase_tree_width => self.adjustTreeWidth(.grow, body_size),
            .tree_first => if (!self.viewer.tree_hidden) self.selectTreeEdge(false, body_height),
            .tree_last => if (!self.viewer.tree_hidden) self.selectTreeEdge(true, body_height),
            .source_first => if (source) |document| repository_navigation.firstSource(&self.viewer, document, source_geometry.?),
            .source_last => if (source) |document| repository_navigation.lastSource(&self.viewer, document, source_geometry.?),
            .toggle_changed_filter => self.toggleChangedFilter(allocator, body_height),
            .toggle_line_numbers => {
                self.viewer.line_numbers = !self.viewer.line_numbers;
                if (source) |document| repository_navigation.clampSource(
                    &self.viewer,
                    document,
                    self.sourceGeometry(body_size, document),
                );
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
                if (self.source_search.match) |match| repository_navigation.revealMatch(&self.viewer, document, match, source_geometry.?) else self.status.set("No source match", .{});
            },
            .clear_source_search => self.source_search.clear(),
            .next_source_match => if (source) |document| {
                self.source_search.match = document.findNext(self.source_search.query.slice(), self.source_search.match);
                if (self.source_search.match) |match| repository_navigation.revealMatch(&self.viewer, document, match, source_geometry.?);
            },
            .previous_source_match => if (source) |document| {
                self.source_search.match = document.findPrevious(self.source_search.query.slice(), self.source_search.match);
                if (self.source_search.match) |match| repository_navigation.revealMatch(&self.viewer, document, match, source_geometry.?);
            },
            .source_search_backspace => self.source_search.input.backspace(),
            .source_search_move_left => self.source_search.input.moveLeft(),
            .source_search_move_right => self.source_search.input.moveRight(),
            .source_search_insert => |codepoint| self.source_search.input.insert(codepoint) catch self.status.set("Source search is too long", .{}),
            .source_search_paste => |text| self.source_search.input.insertSlice(text) catch self.status.set("Source search is too long", .{}),
            .enter_file_search => self.enterFileSearch(),
            .cancel_file_search => self.cancelFileSearch(body_size),
            .submit_file_search => file_search_submitted = self.submitFileSearch(body_size),
            .file_search_previous => self.file_search.move(-1),
            .file_search_next => self.file_search.move(1),
            .file_search_backspace => {
                self.file_search.input.backspace();
                self.refreshFileSearch();
            },
            .file_search_insert => |codepoint| {
                self.file_search.input.insert(codepoint) catch {
                    self.status.set("File search is too long", .{});
                    return result;
                };
                self.refreshFileSearch();
            },
            .file_search_paste => |text| {
                self.file_search.input.insertSlice(text) catch {
                    self.status.set("File search is too long", .{});
                    return result;
                };
                self.refreshFileSearch();
            },
            .manifest_finished, .document_finished, .syntax_finished, .change_map_finished => unreachable,
        }
        if (!optionalPathEql(previous, self.selected_path)) {
            self.invalidateSelectedDocument(allocator);
            result.selected_path_changed = true;
        }
        if (file_search_submitted) self.commitFileSearchSourceFocus();
        return result;
    }

    fn invalidateSelectedDocument(self: *RepositoryPageState, allocator: std.mem.Allocator) void {
        self.clearFileSearchDocumentAuthority();
        self.cancelSourceSelection();
        self.clearCompletedSelection(allocator);
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

    /// Separates scheduling intent from the authority of retained visible
    /// bytes. A terminal request failure may consume retry intent, but it must
    /// never promote the last-good document back to accepted authority.
    fn invalidateDisplayedDocumentAuthority(self: *RepositoryPageState) void {
        if (self.displayed_document) |*document| {
            document.authority = .revalidation_required;
        }
    }

    fn requireDocumentRevalidation(self: *RepositoryPageState) void {
        self.invalidateDisplayedDocumentAuthority();
        self.needs_document_revalidation = self.selected_path != null;
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

    /// Returns a displayed source only when it is also the current accepted
    /// Repository authority. `currentSource()` alone deliberately exposes a
    /// retained last-good document during reload/reactivation; consumers which
    /// commit a new interaction to source focus must not treat that visible
    /// fallback as a validated destination.
    fn acceptedCurrentSourceForSelection(self: *const RepositoryPageState) ?*const source_document.Document {
        if (!self.active or
            self.activation_id == 0 or
            self.root_identity == null or
            self.freshness != .fresh or
            self.needs_revalidation or
            self.needs_document_revalidation or
            self.pending_generation != null or
            self.pending_document_generation != null)
        {
            return null;
        }
        const displayed = if (self.displayed_document) |*document| document else return null;
        if (displayed.authority != .accepted) return null;
        return self.currentSource();
    }

    /// Keep raw page focus valid even when a selected document becomes an
    /// inert checkpoint. Input derives an effective focus too, but lifecycle
    /// reconciliation must never leave an invisible tree as the stored owner.
    fn reconcileNoSourceFocus(self: *RepositoryPageState) void {
        if (self.currentSource() != null) return;
        self.viewer.focus = if (self.viewer.tree_hidden) .source else .tree;
    }

    pub fn inputContext(self: *const RepositoryPageState, keymap: @import("keymap").Effective) repository_input.Context {
        const source_available = self.currentSource() != null;
        return .{
            .focus = if (self.viewer.tree_hidden) .source else if (source_available) self.viewer.focus else .tree,
            .source_available = source_available,
            .tree_hidden = self.viewer.tree_hidden,
            .source_search_mode = self.source_search.mode,
            .file_search_mode = self.file_search.mode,
            .source_query_len = self.source_search.query.len,
            .keymap = keymap,
        };
    }

    fn selectTreeEdge(self: *RepositoryPageState, last: bool, body_height: u16) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        self.viewer.tree_cursor = 0;
        if (self.tree_projection.root_disclosure == .expanded and last) {
            var index = tree.visible_len;
            while (index > 0) {
                index -= 1;
                const node_index = tree.visible[index];
                if (tree.nodes[node_index].kind == .file) {
                    self.viewer.tree_cursor = self.tree_projection.visibleIndexForTarget(
                        tree,
                        .{ .manifest_node = node_index },
                    ) orelse 0;
                    break;
                }
            }
        } else if (self.tree_projection.root_disclosure == .expanded) {
            for (tree.visibleNodes()) |node_index| if (tree.nodes[node_index].kind == .file) {
                self.viewer.tree_cursor = self.tree_projection.visibleIndexForTarget(
                    tree,
                    .{ .manifest_node = node_index },
                ) orelse 0;
                break;
            };
        }
        self.viewer.focus = .tree;
        self.selectCursor();
        self.clampScroll(body_height);
    }

    fn adjustTreeWidth(
        self: *RepositoryPageState,
        direction: repository_layout.WidthDirection,
        body_size: chasen.Size,
    ) void {
        self.viewer.tree_width = repository_layout.adjustedTreeWidth(
            body_size.width,
            self.viewer.tree_width,
            direction,
        );
        self.clampForBodySize(body_size);
    }

    fn preferredTreeHidden(self: *const RepositoryPageState) bool {
        return self.viewer.tree_hidden or (self.file_search.mode and self.file_search.restore_tree_hidden);
    }

    fn toggleTreeVisibility(self: *RepositoryPageState, body_size: chasen.Size) void {
        if (self.viewer.tree_hidden) {
            self.viewer.tree_hidden = false;
            self.viewer.focus = if (self.viewer.tree_return_focus == .source and self.currentSource() == null)
                .tree
            else
                self.viewer.tree_return_focus;
        } else {
            self.viewer.tree_return_focus = self.viewer.focus;
            self.viewer.tree_hidden = true;
            self.viewer.focus = .source;
        }
        self.clampForBodySize(body_size);
    }

    fn enterFileSearch(self: *RepositoryPageState) void {
        self.file_search = .{
            .mode = true,
            .return_focus = self.viewer.focus,
            .restore_tree_hidden = self.viewer.tree_hidden,
        };
        // Search candidates are tree destinations. Revealing the tree for the
        // prompt avoids displaying a focus target in an invisible pane; cancel
        // still owns enough state to restore the user's hidden preference.
        self.viewer.tree_hidden = false;
        self.viewer.focus = .tree;
        self.refreshFileSearch();
    }

    /// Publish candidates only when every basis required by the active lens
    /// is authoritative. In Changed mode an accepted manifest alone is not
    /// enough: missing status is unavailable, not an authoritative empty set.
    fn refreshFileSearch(self: *RepositoryPageState) void {
        if (!self.file_search.mode) return;
        const bundle = if (self.bundle) |*bundle| bundle else {
            self.file_search.resetResults();
            return;
        };
        if (self.file_visibility == .changed and !bundle.status_available) {
            self.file_search.resetResults();
            return;
        }
        repository_navigation.refreshFileSearch(&self.file_search, &bundle.tree, self.file_visibility);
    }

    fn cancelFileSearch(self: *RepositoryPageState, body_size: chasen.Size) void {
        const return_focus = self.file_search.return_focus;
        const restore_tree_hidden = self.file_search.restore_tree_hidden;
        self.file_search.close();
        self.viewer.tree_hidden = restore_tree_hidden;
        self.viewer.focus = if (restore_tree_hidden)
            .source
        else if (return_focus == .source and self.currentSource() == null)
            .tree
        else
            return_focus;
        self.clampForBodySize(body_size);
    }

    fn submitFileSearch(self: *RepositoryPageState, body_size: chasen.Size) bool {
        if (!self.file_search.projection_available) return false;
        const node_index = self.file_search.selectedNode() orelse {
            self.file_search.no_match = true;
            return false;
        };
        const tree = if (self.bundle) |*bundle| &bundle.tree else return false;
        const visible = self.tree_projection.revealManifestNode(tree, self.file_visibility, node_index) orelse return false;
        const selected = tree.nodes[node_index].path;
        // A new successful submit always supersedes an older pane-focus intent.
        // Preserve a typed pending request only for the same-path direct-bind
        // case; changing paths invalidates that request authority immediately.
        self.file_search_source_focus.clear();
        if (!optionalPathEql(self.selected_path, selected)) {
            self.clearPendingDocumentAuthority();
        }
        self.viewer.tree_cursor = visible;
        self.viewer.tree_hidden = false;
        self.viewer.focus = .tree;
        self.selected_path = selected;
        self.file_search.close();
        self.clampForBodySize(body_size);
        return true;
    }

    /// Classify a successful exact candidate after generic selection
    /// invalidation has committed the new path. Until one of these authority
    /// cases succeeds, tree focus is the bounded and truthful terminal.
    fn commitFileSearchSourceFocus(self: *RepositoryPageState) void {
        if (!self.active) return;
        const basis = self.currentFileSearchFocusBasis() orelse return;
        if (self.acceptedCurrentSourceForSelection() != null) {
            self.file_search_source_focus.clear();
            self.viewer.focus = .source;
            return;
        }

        if (self.pending_document_generation) |generation| {
            if (self.pending_document_request) |pending| {
                if (self.file_search_source_focus.bindExisting(basis, generation, pending)) return;
            }
        }

        if (self.wantsDocumentRequest()) {
            self.file_search_source_focus.awaitDocumentRequest(basis);
        } else {
            self.file_search_source_focus.clear();
        }
    }

    fn moveCursor(self: *RepositoryPageState, delta: isize, body_height: u16) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        const visible_len = self.tree_projection.visibleLen(tree);
        if (delta < 0) self.viewer.tree_cursor -|= @intCast(-delta) else self.viewer.tree_cursor = @min(self.viewer.tree_cursor +| @as(usize, @intCast(delta)), visible_len - 1);
        self.selectCursor();
        self.clampScroll(body_height);
    }

    fn setCursor(self: *RepositoryPageState, body_row: usize, body_height: u16, toggle: bool) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        const index = self.viewer.tree_vertical_scroll + body_row;
        const target = self.tree_projection.targetAt(tree, index) orelse return;
        self.viewer.tree_cursor = index;
        if (toggle and switch (target) {
            .repo_root => true,
            .manifest_node => |node_index| tree.nodes[node_index].kind == .directory,
        }) self.toggleCursor(body_height) else self.selectCursor();
    }

    fn toggleCursor(self: *RepositoryPageState, body_height: u16) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        const target = self.tree_projection.targetAt(tree, self.viewer.tree_cursor) orelse return;
        if (self.tree_projection.toggleTarget(tree, self.file_visibility, target)) {
            self.viewer.tree_cursor = @min(
                self.viewer.tree_cursor,
                self.tree_projection.visibleLen(tree) - 1,
            );
            self.clampScroll(body_height);
        } else self.selectCursor();
    }

    fn selectCursor(self: *RepositoryPageState) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        const target = self.tree_projection.targetAt(tree, self.viewer.tree_cursor) orelse return;
        switch (target) {
            .repo_root => {},
            .manifest_node => |node_index| {
                const node = tree.nodes[node_index];
                if (node.kind == .file) {
                    if (!optionalPathEql(self.selected_path, node.path)) {
                        self.clearFileSearchDocumentAuthority();
                    }
                    self.selected_path = node.path;
                }
            },
        }
    }

    pub fn clampScroll(self: *RepositoryPageState, body_height: u16) void {
        const visible_len = if (self.bundle) |*bundle| self.tree_projection.visibleLen(&bundle.tree) else 0;
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
        const layout = bodyLayout(body_size, self.viewer.tree_width, self.viewer.tree_hidden);
        self.clampScroll(layout.treeRows(body_size.height));
        if (self.currentSource()) |document| {
            repository_navigation.clampSource(
                &self.viewer,
                document,
                self.sourceGeometry(body_size, document),
            );
        }
    }

    pub fn activeSourceSelection(self: *const RepositoryPageState) bool {
        return self.source_selection != null;
    }

    pub fn cancelSourceSelection(self: *RepositoryPageState) void {
        self.source_selection = null;
    }

    fn clearCompletedSelection(self: *RepositoryPageState, allocator: std.mem.Allocator) void {
        if (self.completed_selection) |*completed| completed.deinit(allocator);
        self.completed_selection = null;
    }

    /// Reconcile only an already accepted selected-document result. At this
    /// point repo/root/path authority has been checked by `applyDocumentFinished`
    /// and a source result supplies the final fingerprint needed to compare the
    /// complete semantic token. Inert results cannot prove compatible source
    /// bytes and therefore remain fail-closed.
    fn reconcileCompletedSelectionForDocument(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        finished: *const DocumentFinished,
    ) void {
        const completed = if (self.completed_selection) |*selection| selection else return;
        const fingerprint = switch (finished.value) {
            .source => |source| source.fingerprint,
            .inert => {
                self.clearCompletedSelection(allocator);
                return;
            },
        };
        const incoming = repository_selection.RepositoryContentToken{
            .repo_epoch = self.repo_epoch,
            .root_identity = finished.root_identity,
            .path = finished.path,
            .source_fingerprint = fingerprint,
        };
        if (!completed.token.view().eql(incoming)) self.clearCompletedSelection(allocator);
    }

    fn sourceGeometry(self: *const RepositoryPageState, body_size: chasen.Size, document: *const source_document.Document) repository_source_geometry.SourceGeometry {
        const layout = bodyLayout(body_size, self.viewer.tree_width, self.viewer.tree_hidden);
        return .init(
            .{ .width = layout.source_width, .height = body_size.height },
            document,
            self.viewer.line_numbers,
        );
    }

    fn currentContentToken(self: *const RepositoryPageState) ?repository_selection.RepositoryContentToken {
        const displayed = if (self.displayed_document) |*document| document else return null;
        const source = self.currentSource() orelse return null;
        return .{
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity orelse return null,
            .path = displayed.path,
            .source_fingerprint = source.fingerprint,
        };
    }

    fn pointAtTextCell(
        document: *const source_document.Document,
        line_index: usize,
        logical_cell: usize,
    ) ?repository_selection.Point {
        const line = document.lineBody(line_index) orelse return null;
        return switch (text_projection.hitAtDisplayCell(line, logical_cell) orelse return null) {
            .token => |token| repository_selection.pointFromToken(line_index, token),
            .boundary => |boundary| repository_selection.pointFromBoundary(line_index, boundary.offset),
        };
    }

    fn pressSourceSelection(self: *RepositoryPageState, point: BodyPoint, body_size: chasen.Size) void {
        if (self.source_search.mode or self.file_search.mode) return;
        const document = self.currentSource() orelse return;
        const geometry = self.sourceGeometry(body_size, document);
        const line_index = geometry.contentLineAt(point.row, self.viewer.source_vertical_scroll, document) orelse return;
        const region = geometry.regionAt(point.col) orelse return;
        const token = self.currentContentToken() orelse return;
        const mode: repository_selection.Mode = switch (region) {
            .gutter, .line_number => .line,
            .text => .character,
            .separator => return,
        };
        const logical_point = switch (mode) {
            .line => repository_selection.pointFromLine(line_index),
            .character => pointAtTextCell(
                document,
                line_index,
                self.viewer.source_horizontal_scroll + @as(usize, point.col - geometry.text_col),
            ) orelse return,
        };
        self.viewer.focus = .source;
        self.viewer.source_cursor = line_index;
        self.source_selection = repository_selection.DragSelection.initAtCell(token, mode, logical_point, .{ .col = point.col, .row = point.row });
    }

    fn dragSourceSelection(self: *RepositoryPageState, point: ?BodyPoint, body_size: chasen.Size) void {
        const live = self.source_selection orelse return;
        const local = point orelse return;
        const document = self.currentSource() orelse {
            self.cancelSourceSelection();
            return;
        };
        const current_token = self.currentContentToken() orelse {
            self.cancelSourceSelection();
            return;
        };
        if (!live.token.eql(current_token)) {
            self.cancelSourceSelection();
            return;
        }
        const geometry = self.sourceGeometry(body_size, document);
        const line_index = geometry.contentLineAt(local.row, self.viewer.source_vertical_scroll, document) orelse return;
        const region = geometry.regionAt(local.col) orelse return;
        const logical_point: repository_selection.Point = switch (live.mode) {
            .line => repository_selection.pointFromLine(line_index),
            .character => switch (region) {
                .gutter, .line_number => repository_selection.pointFromBoundary(line_index, 0),
                .separator => return,
                .text => pointAtTextCell(
                    document,
                    line_index,
                    self.viewer.source_horizontal_scroll + @as(usize, local.col - geometry.text_col),
                ) orelse return,
            },
        };
        self.viewer.source_cursor = line_index;
        self.source_selection.?.updateAtCell(logical_point, .{ .col = local.col, .row = local.row });
    }

    fn releaseSourceSelection(
        self: *RepositoryPageState,
        allocator: std.mem.Allocator,
        point: ?BodyPoint,
        body_size: chasen.Size,
    ) ?Command {
        if (self.source_selection == null) return null;
        self.dragSourceSelection(point, body_size);
        const live = self.source_selection orelse {
            // A defensive identity failure inside the final drag invalidates
            // the basis for both the gesture and any prior candidate.
            self.clearCompletedSelection(allocator);
            self.status.set("Source selection is no longer current", .{});
            return null;
        };
        if (!live.moved) {
            // A click still updates focus/cursor at press time, but it is not a
            // replacement transaction for the prior release-frozen candidate.
            self.cancelSourceSelection();
            return null;
        }

        const document = self.currentSource() orelse {
            self.clearCompletedSelection(allocator);
            self.cancelSourceSelection();
            self.status.set("Source selection is no longer available", .{});
            return null;
        };
        const current_token = self.currentContentToken() orelse {
            self.clearCompletedSelection(allocator);
            self.cancelSourceSelection();
            self.status.set("Source selection has no current basis", .{});
            return null;
        };
        if (!live.token.eql(current_token)) {
            self.clearCompletedSelection(allocator);
            self.cancelSourceSelection();
            self.status.set("Source selection is no longer current", .{});
            return null;
        }

        var candidate = repository_selection.buildCompletedSelection(allocator, document, live) catch |err| {
            self.clearCompletedSelection(allocator);
            self.cancelSourceSelection();
            self.status.set("Could not complete source selection: {s}", .{@errorName(err)});
            return null;
        };
        self.clearCompletedSelection(allocator);
        self.completed_selection = candidate;
        candidate = undefined;
        self.cancelSourceSelection();

        // A real empty line is a useful line anchor but has no clipboard
        // payload. Keep the candidate and deliberately emit no shell command.
        if (self.completed_selection.?.text.len == 0) {
            self.status.set("Selected source line is empty", .{});
            return null;
        }
        const clipboard = self.completed_selection.?.clipboardText(allocator) catch {
            // Clipboard ownership begins only after candidate acceptance.
            self.status.set("Could not prepare source selection copy", .{});
            return null;
        };
        self.status.clear();
        return .{ .copy_source_selection = clipboard };
    }

    pub fn mouseToMsg(self: *const RepositoryPageState, point: BodyPoint, button: MouseButton, size: chasen.Size) ?Msg {
        const layout = bodyLayout(size, self.viewer.tree_width, self.viewer.tree_hidden);
        if (layout.tree_visible and point.col < layout.tree_width) return switch (button) {
            .wheel_up => .wheel_up,
            .wheel_down => .wheel_down,
            .left => blk: {
                const body_row = layout.treeBodyRow(point) orelse return .focus_tree;
                const tree = if (self.bundle) |*bundle| &bundle.tree else return null;
                const visible_index = self.viewer.tree_vertical_scroll + body_row;
                const target = self.tree_projection.targetAt(tree, visible_index) orelse return null;
                break :blk if (switch (target) {
                    .repo_root => true,
                    .manifest_node => |node_index| tree.nodes[node_index].kind == .directory,
                })
                    .{ .mouse_toggle_row = body_row }
                else
                    .{ .mouse_row = body_row };
            },
        };
        if (point.col < layout.source_col) return null;
        const document = self.currentSource() orelse return null;
        const source_point = sourceGesturePoint(point, size, self.viewer.tree_width, self.viewer.tree_hidden) orelse return null;
        const geometry = self.sourceGeometry(size, document);
        return switch (button) {
            .wheel_up => .mouse_source_wheel_up,
            .wheel_down => .mouse_source_wheel_down,
            .left => if (source_point.row >= geometry.body_first_row) .{ .mouse_source_press = source_point } else .focus_source,
        };
    }
};

fn navigationDismissesIncoming(msg: Msg) bool {
    return switch (msg) {
        .toggle_line_numbers,
        .toggle_tree_visibility,
        .decrease_tree_width,
        .increase_tree_width,
        .cancel_source_selection,
        .cancel_source_search,
        .cancel_file_search,
        .manifest_finished,
        .document_finished,
        .syntax_finished,
        .change_map_finished,
        => false,
        else => true,
    };
}

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
    /// Borrowed active canonical root. The page owns object identity but does
    /// not duplicate path metadata merely to render its safe basename.
    repo_root: ?[]const u8 = null,
};

pub fn view(context: ViewContext, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    const state = context.page_state;
    if (state.incomingUnavailable()) |unavailable| {
        try drawIncomingUnavailable(unavailable, surface, context.palette);
        return;
    }
    if (state.file_search.mode and state.bundle == null) {
        try repository_view.drawFileSearch(surface, null, &state.file_search, context.palette);
        return;
    }
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
        .loading => if (state.file_visibility == .all and !state.file_search.mode) {
            draw.copyClippedTextAt(surface, 1, size.height / 2, "Loading repository files...", context.palette.style(.muted)) catch {};
            return;
        },
        .empty => {},
        .loaded => {},
    }

    const layout = bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    const tree = &state.bundle.?.tree;
    if (layout.tree_visible) {
        var left = surface.child(.{ .col = 0, .row = 0, .width = layout.tree_width, .height = size.height });
        const tree_header: []const u8 = if (state.file_visibility == .changed) " Files [changed]" else " Files";
        // Match Review's literal leading-cell clipping. The ellipsis-producing
        // text helper would turn a width-one title into `…` instead of blank.
        if (size.height > 2) _ = left.borrowTextAt(0, 2, tree_header, context.palette.boldStyle(.accent));
        if (layout.tree_width < size.width) {
            var separator_style = context.palette.style(.muted);
            separator_style.dim = true;
            var separator_row: u16 = 0;
            while (separator_row < size.height) : (separator_row += 1) _ = surface.borrowTextAt(layout.tree_width, separator_row, "│", separator_style);
        }

        const rows = layout.treeRows(size.height);
        const tree_message: ?[]const u8 = if (state.load_state == .empty and state.file_visibility == .all)
            "Repository has no tracked or non-ignored files"
        else if (state.load_state == .loading)
            "Loading changed files..."
        else if (state.file_visibility == .all)
            null
        else if (!treeStatusAvailable(state))
            if (state.freshness == .validating) "Loading changed files..." else "Changed-file status unavailable; press r to retry"
        else if (tree.visible_len == 0)
            "No changed files"
        else
            null;
        if (tree_message) |message| {
            if (rows > 0) try drawTreeProjectionRow(context, &left, tree, 0, layout.header_rows);
            if (rows > 1) draw.copyClippedTextAt(&left, 0, layout.header_rows + 1, message, context.palette.style(.muted)) catch {};
        } else {
            var body_row: usize = 0;
            while (body_row < rows and
                state.viewer.tree_vertical_scroll + body_row < state.tree_projection.visibleLen(tree)) : (body_row += 1)
            {
                const visible_index = state.viewer.tree_vertical_scroll + body_row;
                try drawTreeProjectionRow(
                    context,
                    &left,
                    tree,
                    visible_index,
                    @intCast(body_row + layout.header_rows),
                );
            }
        }
    }

    if (layout.source_width == 0) return;
    var right = surface.child(.{ .col = layout.source_col, .row = 0, .width = layout.source_width, .height = size.height });
    if (state.file_search.mode) {
        try repository_view.drawFileSearch(&right, tree, &state.file_search, context.palette);
        return;
    }
    if (state.selected_path) |path| {
        try repository_view.drawSourceHeader(
            &right,
            path,
            state.source_search,
            state.viewer.focus == .source,
            context.palette,
        );
        if (size.height > repository_source_geometry.source_body_first_row) {
            try drawDocumentCheckpoint(state, path, &right, context.palette);
        }
    } else {
        draw.copyClippedTextAt(
            &right,
            1,
            0,
            "No file selected",
            context.palette.style(.muted),
        ) catch {};
    }
}

fn drawIncomingUnavailable(
    unavailable: *const page_link.RepositoryUnavailable,
    surface: *chasen.Surface,
    palette: theme.Palette,
) !void {
    const size = surface.size();
    draw.copyClippedTextAt(surface, 1, 0, "Repository target unavailable", palette.boldStyle(.danger)) catch {};
    if (size.height > 1) {
        const path = try manifest.displayWindowAlloc(surface.frameAllocator(), unavailable.path, 0, size.width -| 2);
        draw.copyClippedTextAt(surface, 1, 1, path.text(), palette.boldStyle(.accent)) catch {};
    }
    if (size.height > 2) {
        draw.copyClippedTextAt(surface, 1, 2, unavailable.reason.message(), palette.style(.muted)) catch {};
    }
}

fn treeStatusAvailable(state: *const RepositoryPageState) bool {
    return if (state.bundle) |bundle| bundle.status_available else false;
}

fn drawTreeProjectionRow(
    context: ViewContext,
    surface: *chasen.Surface,
    tree: *const repository_tree.Tree,
    visible_index: usize,
    screen_row: u16,
) !void {
    const state = context.page_state;
    const target = state.tree_projection.targetAt(tree, visible_index) orelse return;
    const width = surface.size().width;
    const visible_text: []const u8 = switch (target) {
        .repo_root => try rootRowTextAlloc(
            surface.frameAllocator(),
            repositoryRootName(context.repo_root),
            state.tree_projection.root_disclosure,
            state.viewer.tree_horizontal_scroll,
            width,
        ),
        .manifest_node => |node_index| try treeRowTextAlloc(
            surface.frameAllocator(),
            tree.nodes[node_index],
            state.viewer.tree_horizontal_scroll,
            width,
        ),
    };
    var style = switch (target) {
        .repo_root => context.palette.boldStyle(.accent),
        .manifest_node => |node_index| blk: {
            const node = tree.nodes[node_index];
            if (node.kind == .directory) break :blk context.palette.boldStyle(.accent);
            if (node.file_change) |change| break :blk context.palette.style(switch (change) {
                .added => .diff_added,
                .modified => .diff_modified,
            });
            break :blk context.palette.style(.foreground);
        },
    };
    const selected = visible_index == state.viewer.tree_cursor;
    const cursor_background_active = selected and
        state.viewer.focus == .tree and
        !state.file_search.mode;
    // Selection contributes neutral cursor chrome only. The target keeps
    // ownership of its semantic foreground so directories and changed files
    // remain distinguishable in both active and retained-inactive tree states.
    // File search temporarily owns navigation while retaining the tree cursor,
    // so its candidate emphasis—not that stored destination—owns focus chrome.
    // The same low-intensity background as the source cursor avoids the much
    // stronger terminal-dependent foreground/background swap from reverse.
    if (selected) {
        style.bold = true;
    }
    if (cursor_background_active) {
        style.bg = context.palette.color(.pane_cursor_bg);
        fillTreeSelectionRow(surface, screen_row, style);
    }
    draw.copyClippedTextAt(surface, 0, screen_row, visible_text, style) catch {};
}

/// Extend the selected row's composed semantic foreground and neutral cursor
/// background through the physical tree viewport. The separator is outside
/// this child surface, so it remains fixed chrome rather than becoming part of
/// the selection signal.
fn fillTreeSelectionRow(surface: *chasen.Surface, row: u16, style: chasen.TextStyle) void {
    for (0..surface.size().width) |col| {
        _ = surface.borrowTextAt(@intCast(col), row, " ", style);
    }
}

fn repositoryRootName(root: ?[]const u8) []const u8 {
    const path = root orelse return "Repository";
    const base = std.fs.path.basename(path);
    return if (base.len == 0) path else base;
}

fn drawDocumentCheckpoint(
    state: *const RepositoryPageState,
    selected_path: []const u8,
    surface: *chasen.Surface,
    palette: theme.Palette,
) !void {
    const displayed = state.displayed_document orelse {
        draw.copyClippedTextAt(surface, 1, repository_source_geometry.source_body_first_row, "Loading selected file...", palette.style(.muted)) catch {};
        return;
    };
    if (displayed.manifest_revision != state.manifest_revision or !std.mem.eql(u8, displayed.path, selected_path)) {
        draw.copyClippedTextAt(surface, 1, repository_source_geometry.source_body_first_row, "Loading selected file...", palette.style(.muted)) catch {};
        return;
    }
    switch (displayed.value) {
        .source => |*source| {
            const live_selection = if (state.source_selection) |selection|
                if (state.currentContentToken()) |token|
                    if (selection.token.eql(token)) selection else null
                else
                    null
            else
                null;
            try repository_view.drawSource(
                surface,
                source,
                &displayed.syntax_spans,
                displayed.change_decoration.map(),
                state.viewer,
                state.source_search,
                live_selection,
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
    draw.copyClippedTextAt(surface, 1, repository_source_geometry.source_body_first_row, label, palette.style(.muted)) catch {};
}

fn treeRowTextAlloc(
    allocator: std.mem.Allocator,
    node: repository_tree.Node,
    horizontal_scroll: usize,
    width: u16,
) ![]const u8 {
    const marker: []const u8 = switch (node.kind) {
        .file => "  ",
        .directory => if (node.expanded) "▾ " else "▸ ",
    };
    return treeItemTextAlloc(
        allocator,
        (node.depth + 1) * 2,
        marker,
        node.name,
        horizontal_scroll,
        width,
    );
}

fn rootRowTextAlloc(
    allocator: std.mem.Allocator,
    name: []const u8,
    disclosure: repository_tree_projection.RootDisclosure,
    horizontal_scroll: usize,
    width: u16,
) ![]const u8 {
    return treeItemTextAlloc(allocator, 0, disclosure.glyph(), name, horizontal_scroll, width);
}

fn treeItemTextAlloc(
    allocator: std.mem.Allocator,
    logical_indent: usize,
    marker: []const u8,
    name: []const u8,
    horizontal_scroll: usize,
    width: u16,
) ![]const u8 {
    if (width == 0) return "";
    const available: usize = width;
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
    const name_window = try manifest.displayWindowAlloc(allocator, name, skip, name_width);
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

test "repository transition E1 exports only resolved exact Review context" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 5, .inode = 8 };
    const exact_path = "src/\xff.zig";
    var state: RepositoryPageState = .{
        .repo_epoch = 13,
        .root_identity = identity,
        .selected_path = exact_path,
    };
    defer state.deinit(allocator);

    switch (state.reviewTarget()) {
        .no_context => return error.ExpectedReviewLocation,
        .location => |location| {
            try std.testing.expectEqual(@as(u64, 13), location.repo_epoch);
            try std.testing.expect(location.root_identity.eql(identity));
            try std.testing.expect(std.mem.eql(u8, exact_path, location.path));
            try std.testing.expectEqual(@intFromPtr(state.selected_path.?.ptr), @intFromPtr(location.path.ptr));
        },
    }

    state.selected_path = null;
    try std.testing.expect(state.reviewTarget() == .no_context);
    state.selected_path = exact_path;
    state.root_identity = null;
    try std.testing.expect(state.reviewTarget() == .no_context);
}

test "repository transition E1 pending and unavailable destinations suppress retained context" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .repo_epoch = 13,
        .root_identity = identity,
        .selected_path = "retained.zig",
    };
    defer state.deinit(allocator);

    var pending = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        identity,
        .{ .location = .{ .path = "requested.zig" } },
    );
    state.acceptIncoming(allocator, &pending);
    try std.testing.expect(state.reviewTarget() == .no_context);

    try std.testing.expect(state.incoming.advanceToDocument(21));
    try std.testing.expect(state.reviewTarget() == .no_context);

    try std.testing.expect(state.terminalizeIncoming(.path_not_found));
    try std.testing.expect(state.reviewTarget() == .no_context);

    state.dismissIncoming(allocator);
    switch (state.reviewTarget()) {
        .no_context => return error.ExpectedRetainedReviewLocation,
        .location => |location| try std.testing.expectEqualStrings("retained.zig", location.path),
    }
}

test "repository page navigation keeps sticky file selection on directory and root" {
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
    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.collapsed, state.tree_projection.root_disclosure);
    try std.testing.expectEqual(@as(usize, 1), state.tree_projection.visibleLen(&state.bundle.?.tree));
    _ = state.applyNavigation(std.testing.allocator, .toggle_directory, .{ .width = 60, .height = 11 });
    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.expanded, state.tree_projection.root_disclosure);
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
    state.refreshFileSearch();
    try std.testing.expectEqual(@as(usize, 1), state.file_search.len);

    var incoming = try bundleForTest("new.zig\x00");
    errdefer incoming.deinit(allocator);
    try state.replaceBundle(allocator, &incoming);
    try std.testing.expectEqual(@as(usize, 0), state.file_search.len);
    try std.testing.expect(state.file_search.no_match);
}

test "repository All replacement restores typed directory cursor beside hidden selection" {
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
    try std.testing.expectEqual(@as(usize, 1), state.viewer.tree_cursor);
    try std.testing.expectEqualStrings("dir/selected.zig", state.selected_path.?);
}

test "repository manifest replacement retains collapsed root and selected source" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("dir/selected.zig\x00root.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("dir/selected.zig", .all);
    state.tree_projection.root_disclosure = .collapsed;
    state.viewer.tree_cursor = 0;
    state.viewer.tree_width = 42;
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;

    var incoming = try bundleForTest("dir/selected.zig\x00root.zig\x00");
    var incoming_owned = true;
    defer if (incoming_owned) incoming.deinit(allocator);
    try state.replaceBundle(allocator, &incoming);
    incoming_owned = false;

    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.collapsed, state.tree_projection.root_disclosure);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), state.tree_projection.visibleLen(&state.bundle.?.tree));
    try std.testing.expectEqualStrings("dir/selected.zig", state.selected_path.?);
}

test "repository explicit reload restores typed root and directory across outcomes" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("dir/selected.zig\x00root.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.activate(7, root.capability.identity);
    state.selected_path = state.bundle.?.tree.filePath("dir/selected.zig", .all);
    state.tree_projection.root_disclosure = .collapsed;
    state.viewer.tree_cursor = 0;
    state.viewer.tree_width = 42;
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;

    state.requestReload(true);
    var unchanged_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer unchanged_request.deinit(allocator);
    var unchanged: ManifestFinished = .{
        .identity = unchanged_request.identity,
        .root_identity = unchanged_request.root.identity,
        .generation = unchanged_request.generation,
        .result = .{ .unchanged = state.bundle.?.document.fingerprint },
    };
    defer unchanged.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.unchanged, state.applyFinished(allocator, &unchanged));
    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.collapsed, state.tree_projection.root_disclosure);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqualStrings("dir/selected.zig", state.selected_path.?);

    state.tree_projection.root_disclosure = .expanded;
    const directory = state.bundle.?.tree.nodeIndexForPath("dir", .all) orelse return error.ExpectedDirectory;
    state.viewer.tree_cursor = state.tree_projection.visibleIndexForTarget(
        &state.bundle.?.tree,
        .{ .manifest_node = directory },
    ) orelse return error.ExpectedVisibleDirectory;

    state.requestReload(true);
    var changed_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer changed_request.deinit(allocator);
    var changed: ManifestFinished = .{
        .identity = changed_request.identity,
        .root_identity = changed_request.root.identity,
        .generation = changed_request.generation,
        .result = .{ .loaded = try bundleForTest("dir/selected.zig\x00new.zig\x00root.zig\x00") },
    };
    defer changed.deinit(allocator);

    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &changed));
    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.expanded, state.tree_projection.root_disclosure);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    const restored = state.tree_projection.targetAt(&state.bundle.?.tree, state.viewer.tree_cursor) orelse
        return error.ExpectedRestoredTarget;
    switch (restored) {
        .repo_root => return error.ExpectedDirectory,
        .manifest_node => |node_index| try std.testing.expectEqualStrings("dir", state.bundle.?.tree.nodes[node_index].path),
    }
    try std.testing.expectEqualStrings("dir/selected.zig", state.selected_path.?);
    try std.testing.expect(state.needs_document_revalidation);
}

test "repository manifest replacement falls deleted directory cursor to visible ancestor" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("a/nested/selected.zig\x00a/kept.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("a/nested/selected.zig", .all);
    const nested = state.bundle.?.tree.nodeIndexForPath("a/nested", .all) orelse return error.ExpectedDirectory;
    state.viewer.tree_cursor = state.tree_projection.visibleIndexForTarget(
        &state.bundle.?.tree,
        .{ .manifest_node = nested },
    ) orelse return error.ExpectedVisibleDirectory;

    var incoming = try bundleForTest("a/kept.zig\x00");
    var incoming_owned = true;
    defer if (incoming_owned) incoming.deinit(allocator);
    try state.replaceBundle(allocator, &incoming);
    incoming_owned = false;

    const target = state.tree_projection.targetAt(&state.bundle.?.tree, state.viewer.tree_cursor) orelse
        return error.ExpectedRestoredTarget;
    switch (target) {
        .repo_root => return error.ExpectedDirectoryAncestor,
        .manifest_node => |node_index| try std.testing.expectEqualStrings("a", state.bundle.?.tree.nodes[node_index].path),
    }
}

test "repository file search expands typed root before selecting result" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("dir/target.zig\x00other.zig\x00"),
        .load_state = .loaded,
        .tree_projection = .{ .root_disclosure = .collapsed },
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("other.zig", .all);
    state.file_search.mode = true;
    try state.file_search.input.insertSlice("target");
    state.refreshFileSearch();

    _ = state.applyNavigation(allocator, .submit_file_search, .{ .width = 80, .height = 10 });

    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.expanded, state.tree_projection.root_disclosure);
    try std.testing.expectEqualStrings("dir/target.zig", state.selected_path.?);
    const selected_target = state.tree_projection.targetAt(&state.bundle.?.tree, state.viewer.tree_cursor) orelse
        return error.ExpectedSearchTarget;
    switch (selected_target) {
        .repo_root => return error.ExpectedFileTarget,
        .manifest_node => |node_index| try std.testing.expectEqualStrings("dir/target.zig", state.bundle.?.tree.nodes[node_index].path),
    }
}

test "repository empty file search accepts the focused exact candidate" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("alpha.zig\x00beta.zig\x00"),
        .load_state = .loaded,
        .viewer = .{ .focus = .source, .tree_hidden = true },
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("beta.zig", .all);
    const size: chasen.Size = .{ .width = 80, .height = 10 };

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(!state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqualStrings("alpha.zig", state.selected_path.?);

    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;
    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .file_search_previous, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(!state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqualStrings("alpha.zig", state.selected_path.?);
}

test "repository empty file search retains authoritative zero-candidate prompt" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest(""),
        .load_state = .loaded,
        .viewer = .{ .focus = .source, .tree_hidden = true },
    };
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 80, .height = 8 };

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    try std.testing.expect(state.file_search.projection_available);
    try std.testing.expect(state.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), state.file_search.len);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search.mode);
    try std.testing.expect(state.file_search.no_match);
    try std.testing.expect(!state.viewer.tree_hidden);

    _ = state.applyNavigation(allocator, .cancel_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
}

test "repository file search takeover suppresses and restores tree cursor background" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("alpha.zig\x00beta.zig\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    const tree = &state.bundle.?.tree;
    state.selected_path = tree.filePath("alpha.zig", .all);
    const alpha_node = tree.nodeIndexForPath("alpha.zig", .all) orelse return error.ExpectedAlphaFile;
    const alpha_visible = state.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = alpha_node }) orelse
        return error.ExpectedAlphaFile;
    state.viewer.tree_cursor = alpha_visible;
    state.viewer.focus = .tree;

    const palette = repositorySearchCursorPaletteForTest();
    const size: chasen.Size = .{ .width = 60, .height = 10 };
    const layout = bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    const alpha_row = layout.header_rows + @as(u16, @intCast(alpha_visible));

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(size.width, size.height);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const initial_alpha = test_surface.surface.readCell(2, alpha_row) orelse return error.ExpectedAlphaFile;
    const initial_alpha_trailing = test_surface.surface.readCell(layout.tree_width - 1, alpha_row) orelse
        return error.ExpectedAlphaTrailingCell;
    try std.testing.expect(initial_alpha.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(initial_alpha_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    for ("zig") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, size);
    try std.testing.expectEqual(@as(usize, 2), state.file_search.len);
    const retained_tree_cursor = state.viewer.tree_cursor;
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const search_alpha = test_surface.surface.readCell(2, alpha_row) orelse return error.ExpectedAlphaFile;
    const search_alpha_trailing = test_surface.surface.readCell(layout.tree_width - 1, alpha_row) orelse
        return error.ExpectedAlphaTrailingCell;
    const first_candidate = test_surface.surface.readCell(layout.source_col + 1, 2) orelse
        return error.ExpectedSearchCandidate;
    try std.testing.expect(!search_alpha.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!search_alpha_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(first_candidate.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(first_candidate.style.bold);

    _ = state.applyNavigation(allocator, .file_search_next, size);
    try std.testing.expectEqual(retained_tree_cursor, state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.file_search.focused);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const moved_candidate = test_surface.surface.readCell(layout.source_col + 1, 3) orelse
        return error.ExpectedSearchCandidate;
    try std.testing.expect(moved_candidate.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(moved_candidate.style.bold);

    _ = state.applyNavigation(allocator, .cancel_file_search, size);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const restored_alpha_trailing = test_surface.surface.readCell(layout.tree_width - 1, alpha_row) orelse
        return error.ExpectedAlphaTrailingCell;
    try std.testing.expect(restored_alpha_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const empty_accept_alpha_trailing = test_surface.surface.readCell(layout.tree_width - 1, alpha_row) orelse
        return error.ExpectedAlphaTrailingCell;
    try std.testing.expect(empty_accept_alpha_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    for ("beta") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expectEqualStrings("beta.zig", state.selected_path.?);
    const beta_node = tree.nodeIndexForPath("beta.zig", .all) orelse return error.ExpectedBetaFile;
    const beta_visible = state.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = beta_node }) orelse
        return error.ExpectedBetaFile;
    const beta_row = layout.header_rows + @as(u16, @intCast(beta_visible));
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const accepted_beta_trailing = test_surface.surface.readCell(layout.tree_width - 1, beta_row) orelse
        return error.ExpectedBetaTrailingCell;
    try std.testing.expect(accepted_beta_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    for ("missing") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search.mode);
    try std.testing.expect(state.file_search.no_match);
    test_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const no_match_beta_trailing = test_surface.surface.readCell(layout.tree_width - 1, beta_row) orelse
        return error.ExpectedBetaTrailingCell;
    const no_match_prompt = test_surface.surface.readCell(layout.source_col + 1, 0) orelse
        return error.ExpectedSearchPrompt;
    try std.testing.expect(!no_match_beta_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(no_match_prompt.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(no_match_prompt.style.bold);
}

test "repository hidden tree gives source full geometry and restores retained focus" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest(
        "a.zig\x00b.zig\x00c.zig\x00d.zig\x00e.zig\x00f.zig\x00",
        "one\ntwo\nthree\n",
    );
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 80, .height = 6 };
    state.viewer.focus = .tree;
    state.viewer.tree_width = 42;
    state.viewer.tree_cursor = 4;
    state.viewer.tree_vertical_scroll = 2;
    state.viewer.tree_horizontal_scroll = 7;
    const selected = state.selected_path.?;

    _ = state.applyNavigation(allocator, .toggle_tree_visibility, size);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
    try std.testing.expectEqual(@as(usize, 4), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(usize, 2), state.viewer.tree_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 7), state.viewer.tree_horizontal_scroll);
    try std.testing.expectEqualStrings(selected, state.selected_path.?);
    const hidden_layout = bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    try std.testing.expect(!hidden_layout.tree_visible);
    try std.testing.expectEqual(@as(u16, 0), hidden_layout.source_col);
    try std.testing.expectEqual(size.width, hidden_layout.source_width);
    try std.testing.expectEqual(size.width, state.sourceGeometry(size, state.currentSource().?).width);
    try std.testing.expectEqual(
        Msg.focus_source,
        state.mouseToMsg(.{ .col = 0, .row = 0 }, .left, size).?,
    );
    try std.testing.expectEqual(
        BodyPoint{ .col = 4, .row = 2 },
        sourceGesturePoint(.{ .col = 4, .row = 2 }, size, state.viewer.tree_width, true).?,
    );

    var hidden_surface: chasen.testing.TestSurface = undefined;
    try hidden_surface.init(size.width, size.height);
    defer hidden_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/gitframe" }, &hidden_surface.surface);
    const hidden_snapshot = try hidden_surface.snapshot(allocator);
    defer allocator.free(hidden_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, hidden_snapshot, "Files") == null);
    try hidden_surface.expectCellText(1, repository_source_geometry.source_path_row, "a");

    _ = state.applyNavigation(allocator, .toggle_tree_visibility, size);
    try std.testing.expect(!state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 4), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(usize, 2), state.viewer.tree_vertical_scroll);
    try std.testing.expectEqual(@as(usize, 7), state.viewer.tree_horizontal_scroll);

    state.viewer.focus = .source;
    _ = state.applyNavigation(allocator, .toggle_tree_visibility, size);
    const repo_epoch = state.repo_epoch;
    const root_identity = state.root_identity.?;
    state.deactivate();
    state.activate(repo_epoch, root_identity);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
    _ = state.applyNavigation(allocator, .toggle_tree_visibility, size);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
}

test "repository hidden-tree file search restores on cancel and commits visible on success" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("dir/target.zig\x00other.zig\x00"),
        .load_state = .loaded,
        .tree_projection = .{ .root_disclosure = .collapsed },
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("other.zig", .all);
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;
    const size: chasen.Size = .{ .width = 80, .height = 10 };
    const palette = repositorySearchCursorPaletteForTest();

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    for ("target") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, size);
    const search_layout = bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    var search_surface: chasen.testing.TestSurface = undefined;
    try search_surface.init(size.width, size.height);
    defer search_surface.deinit();
    try view(.{ .page_state = &state, .palette = palette }, &search_surface.surface);
    const retained_root = search_surface.surface.readCell(0, search_layout.header_rows) orelse
        return error.ExpectedRepositoryRoot;
    const retained_root_trailing = search_surface.surface.readCell(search_layout.tree_width - 1, search_layout.header_rows) orelse
        return error.ExpectedRepositoryRootTrailingCell;
    const focused_candidate = search_surface.surface.readCell(search_layout.source_col + 1, 2) orelse
        return error.ExpectedSearchCandidate;
    try std.testing.expect(!retained_root.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!retained_root_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(focused_candidate.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(focused_candidate.style.bold);

    state.file_search.input.clear();
    state.refreshFileSearch();
    try state.file_search.input.insertSlice("missing");
    state.refreshFileSearch();
    try std.testing.expect(state.file_search.mode);
    try std.testing.expect(state.file_search.restore_tree_hidden);
    try std.testing.expect(!state.viewer.tree_hidden);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search.mode);
    try std.testing.expect(state.file_search.no_match);
    try std.testing.expect(!state.viewer.tree_hidden);

    _ = state.applyNavigation(allocator, .cancel_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqualStrings("other.zig", state.selected_path.?);

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .cancel_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    for ("target") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(!state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.expanded, state.tree_projection.root_disclosure);
    try std.testing.expectEqualStrings("dir/target.zig", state.selected_path.?);
    const tree = &state.bundle.?.tree;
    const target_node = tree.nodeIndexForPath("dir/target.zig", .all) orelse return error.ExpectedSearchTarget;
    const target_visible = state.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = target_node }) orelse
        return error.ExpectedSearchTarget;
    const target_row = search_layout.header_rows + @as(u16, @intCast(target_visible));
    search_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &search_surface.surface);
    const accepted_target_trailing = search_surface.surface.readCell(search_layout.tree_width - 1, target_row) orelse
        return error.ExpectedSearchTargetTrailingCell;
    try std.testing.expect(accepted_target_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
}

test "repository hidden-tree file search keeps unavailable prompt cancellable" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .load_state = .loading,
        .viewer = .{ .focus = .source, .tree_width = 42, .tree_hidden = true },
    };
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 80, .height = 8 };

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search.mode);
    try std.testing.expectEqualStrings("", state.file_search.input.slice());
    try std.testing.expect(!state.file_search.projection_available);
    try std.testing.expect(!state.file_search.no_match);
    try std.testing.expect(!state.viewer.tree_hidden);

    _ = state.applyNavigation(allocator, .{ .file_search_insert = 'x' }, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search.mode);
    try std.testing.expect(!state.file_search.projection_available);
    try std.testing.expect(!state.file_search.no_match);
    try std.testing.expect(!state.viewer.tree_hidden);

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(size.width, size.height);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Find file: x") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "File list unavailable") != null);

    _ = state.applyNavigation(allocator, .cancel_file_search, size);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
}

test "repository changed file search retains its transaction when status basis is unavailable" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("target.zig\x00"),
        .load_state = .loaded,
        .file_visibility = .changed,
        .viewer = .{ .focus = .source, .tree_hidden = true },
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.filePath("target.zig", .all);
    const size: chasen.Size = .{ .width = 80, .height = 8 };
    const palette = repositorySearchCursorPaletteForTest();

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    for ("target") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, size);
    try std.testing.expect(!state.file_search.projection_available);
    try std.testing.expect(!state.file_search.no_match);
    try std.testing.expect(state.file_search.selectedNode() == null);

    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search.mode);
    try std.testing.expectEqualStrings("target", state.file_search.input.slice());
    try std.testing.expect(state.file_search.restore_tree_hidden);
    try std.testing.expect(!state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqualStrings("target.zig", state.selected_path.?);

    const layout = bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(size.width, size.height);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
    const retained_root = test_surface.surface.readCell(0, layout.header_rows) orelse
        return error.ExpectedRepositoryRoot;
    const retained_root_trailing = test_surface.surface.readCell(layout.tree_width - 1, layout.header_rows) orelse
        return error.ExpectedRepositoryRootTrailingCell;
    const prompt = test_surface.surface.readCell(layout.source_col + 1, 0) orelse
        return error.ExpectedSearchPrompt;
    try std.testing.expect(!retained_root.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!retained_root_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(prompt.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(prompt.style.bold);
}

test "repository changed file search reclassifies status-only availability transitions" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("target.zig\x00clean.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 7,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M target.zig\x00");
    state.activate(3, root.capability.identity);
    state.selected_path = state.bundle.?.tree.filePath("target.zig", .all);
    _ = state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 8 });
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;
    _ = state.applyNavigation(allocator, .enter_file_search, .{ .width = 80, .height = 8 });
    for ("target") |byte| _ = state.applyNavigation(allocator, .{ .file_search_insert = byte }, .{ .width = 80, .height = 8 });
    try std.testing.expect(state.file_search.projection_available);
    try std.testing.expect(!state.file_search.no_match);
    try std.testing.expect(state.file_search.selectedNode() != null);

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
    try std.testing.expect(state.file_search.mode);
    try std.testing.expectEqualStrings("target", state.file_search.input.slice());
    try std.testing.expect(!state.file_search.projection_available);
    try std.testing.expect(!state.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), state.file_search.len);
    try std.testing.expect(state.file_search.selectedNode() == null);
    try std.testing.expect(state.file_search.restore_tree_hidden);
    try std.testing.expect(!state.viewer.tree_hidden);

    _ = state.applyNavigation(allocator, .submit_file_search, .{ .width = 80, .height = 8 });
    try std.testing.expect(state.file_search.mode);
    try std.testing.expect(!state.file_search.projection_available);

    state.needs_revalidation = true;
    var available_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer available_request.deinit(allocator);
    var available_empty = ManifestFinished{
        .identity = available_request.identity,
        .root_identity = available_request.root.identity,
        .generation = available_request.generation,
        .result = .{ .status_changed = .{ .loaded = try repository_change_index.parseOwned(
            allocator,
            try allocator.dupe(u8, ""),
        ) } },
    };
    defer available_empty.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &available_empty));
    try std.testing.expect(state.file_search.mode);
    try std.testing.expectEqualStrings("target", state.file_search.input.slice());
    try std.testing.expect(state.file_search.projection_available);
    try std.testing.expect(state.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), state.file_search.len);
    try std.testing.expect(state.file_search.selectedNode() == null);
    try std.testing.expect(state.file_search.restore_tree_hidden);
    try std.testing.expect(!state.viewer.tree_hidden);
}

test "repository hidden tree keeps source focus when document becomes inert" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "visible source\n");
    defer state.deinit(allocator);
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;
    state.document_generation = 8;
    state.pending_document_generation = 8;

    var finished: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 8,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, state.selected_path.?),
        .value = .{ .inert = .binary },
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqualStrings("main.zig", state.selected_path.?);
    try std.testing.expect(state.currentSource() == null);
    try std.testing.expect(state.displayed_document.?.value == .inert);

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(80, 8);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Binary file is not shown") != null);
}

test "repository replacement retains hidden preference behind temporary search reveal" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("target.zig\x00"),
        .load_state = .loaded,
        .file_visibility = .changed,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.viewer.tree_width = 42;
    state.viewer.tree_hidden = true;
    state.viewer.focus = .source;
    _ = state.applyNavigation(allocator, .enter_file_search, .{ .width = 80, .height = 10 });
    try std.testing.expect(!state.viewer.tree_hidden);
    try std.testing.expect(state.file_search.restore_tree_hidden);

    state.repositoryChanged(allocator, 9, .{ .device = 8, .inode = 13 });
    try std.testing.expect(state.viewer.tree_hidden);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expect(!state.file_search.mode);
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.expanded, state.tree_projection.root_disclosure);
    try std.testing.expect(state.selected_path == null);
}

fn repositorySearchCursorPaletteForTest() theme.Palette {
    const Config = struct {
        pub fn get(_: @This(), role: theme.Role) ?theme.ColorValue {
            return switch (role) {
                .prompt => .{ .rgb = .{ .r = 31, .g = 32, .b = 33 } },
                .pane_cursor_bg => .{ .rgb = .{ .r = 41, .g = 42, .b = 43 } },
                else => null,
            };
        }
    };
    return theme.Palette.fromConfig(Config{});
}

fn bundleForTest(bytes: []const u8) !Bundle {
    var document = try manifest.parseOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
    errdefer document.deinit(std.testing.allocator);
    return .{ .tree = try repository_tree.Tree.build(std.testing.allocator, &document), .document = document };
}

fn selectionStateForTest(paths: []const u8, content: []const u8) !RepositoryPageState {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 3,
        .root_identity = .{ .device = 4, .inode = 5 },
        .bundle = try bundleForTest(paths),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    errdefer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.viewer.tree_cursor = 1;
    const bytes = try allocator.dupe(u8, content);
    var document = try source_document.Document.initOwned(allocator, bytes, .init(bytes));
    errdefer document.deinit(allocator);
    const path = try allocator.dupe(u8, state.selected_path.?);
    state.displayed_document = .{
        .path = path,
        .manifest_revision = state.manifest_revision,
        .source_revision = 7,
        .authority = .accepted,
        .value = .{ .source = document },
    };
    return state;
}

fn installFirstLineCandidateForTest(
    state: *RepositoryPageState,
    allocator: std.mem.Allocator,
) !void {
    const document = state.currentSource() orelse return error.ExpectedSource;
    var drag = repository_selection.DragSelection.init(
        state.currentContentToken() orelse return error.ExpectedContentToken,
        .line,
        repository_selection.pointFromLine(0),
    );
    drag.moved = true;
    var completed = try repository_selection.buildCompletedSelection(allocator, document, drag);
    state.clearCompletedSelection(allocator);
    state.completed_selection = completed;
    completed = undefined;
}

fn expectDocumentReplacementCandidateForTest(content: ?[]const u8, retained: bool) !void {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "old source\n");
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);
    state.document_generation = 8;
    state.pending_document_generation = 8;

    const value: DocumentValue = if (content) |bytes| blk: {
        const owned = try allocator.dupe(u8, bytes);
        break :blk .{ .source = try source_document.Document.initOwned(allocator, owned, .init(owned)) };
    } else .{ .inert = .binary };
    var finished: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 8,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, state.selected_path.?),
        .value = value,
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    try std.testing.expectEqual(retained, state.completed_selection != null);
    if (retained) {
        try std.testing.expectEqualStrings("old source", state.completed_selection.?.text);
        try std.testing.expect(state.completed_selection.?.token.view().eql(state.currentContentToken().?));
    }
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
        .authority = .accepted,
        .value = .{ .inert = .binary },
    };

    try std.testing.expect(!state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);
    try std.testing.expectEqualStrings("changed.zig", state.selected_path.?);
    try std.testing.expectEqualStrings("changed.zig", state.all_selection_anchor.?);
    try std.testing.expect(state.displayed_document != null);
    try std.testing.expect(!state.needs_document_revalidation);

    try std.testing.expect(!state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
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
        .authority = .accepted,
        .value = .{ .inert = .binary },
    };

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expectEqualStrings("changed.zig", state.selected_path.?);
    try std.testing.expectEqualStrings("clean.zig", state.all_selection_anchor.?);
    try std.testing.expect(state.displayed_document == null);
    try std.testing.expect(state.needs_document_revalidation);

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
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
    state.viewer.tree_cursor = 1;
    const size = chasen.Size{ .width = 80, .height = 10 };
    _ = state.applyNavigation(allocator, .toggle_changed_filter, size);
    try std.testing.expectEqual(@as(usize, 2), state.bundle.?.tree.visible_len);

    _ = state.applyNavigation(allocator, .move_down, size);
    try std.testing.expectEqualStrings("c-change.zig", state.selected_path.?);
    const mouse_msg = state.mouseToMsg(.{ .col = 1, .row = 4 }, .left, size) orelse return error.ExpectedFilteredMouseRow;
    _ = state.applyNavigation(allocator, mouse_msg, size);
    try std.testing.expectEqualStrings("a-change.zig", state.selected_path.?);
    _ = state.applyNavigation(allocator, .tree_last, size);
    try std.testing.expectEqualStrings("c-change.zig", state.selected_path.?);
    state.viewer.tree_cursor = 99;
    state.viewer.tree_vertical_scroll = 99;
    state.clampForBodySize(.{ .width = 24, .height = 2 });
    try std.testing.expect(state.viewer.tree_cursor < state.tree_projection.visibleLen(&state.bundle.?.tree));
    try std.testing.expect(state.viewer.tree_vertical_scroll < state.tree_projection.visibleLen(&state.bundle.?.tree));
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
        .authority = .accepted,
        .value = .{ .inert = .binary },
    };

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expect(state.selected_path == null);
    try std.testing.expect(state.displayed_document == null);
    try std.testing.expect(!state.needs_document_revalidation);
    try std.testing.expectEqualStrings("clean.zig", state.all_selection_anchor.?);

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
    try std.testing.expectEqualStrings("clean.zig", state.selected_path.?);
    try std.testing.expect(state.needs_document_revalidation);
    const generation = state.document_generation;
    try std.testing.expect(!state.applyNavigation(allocator, .tree_first, .{ .width = 80, .height = 10 }).selected_path_changed);
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
    try std.testing.expect(!state.applyNavigation(failing.allocator(), .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
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
    state.tree_projection.root_disclosure = .collapsed;
    state.viewer.tree_cursor = 0;
    state.viewer.tree_width = 42;

    state.deactivate();
    state.activate(4, identity);
    try std.testing.expectEqual(repository_tree.Visibility.changed, state.file_visibility);
    try std.testing.expectEqualStrings("clean.zig", state.all_selection_anchor.?);
    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.collapsed, state.tree_projection.root_disclosure);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);

    state.repositoryChanged(allocator, 5, .{ .device = 3, .inode = 4 });
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expect(state.all_selection_anchor == null);
    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.expanded, state.tree_projection.root_disclosure);
    try std.testing.expectEqual(@as(usize, 0), state.viewer.tree_cursor);
    try std.testing.expectEqual(@as(?u16, 42), state.viewer.tree_width);
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
            .authority = .accepted,
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
            .authority = .accepted,
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

    try std.testing.expect(state.applyNavigation(allocator, .toggle_changed_filter, .{ .width = 80, .height = 10 }).selected_path_changed);
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

test "repository tree cursor background follows active focus and preserves semantic palette roles" {
    const allocator = std.testing.allocator;
    var bundle = try bundleForTest("added.zig\x00dir/nested.zig\x00modified.zig\x00selected.zig\x00");
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
    const tree = &state.bundle.?.tree;
    state.selected_path = tree.filePath("selected.zig", .all);
    const selected_node = tree.nodeIndexForPath("selected.zig", .all) orelse return error.ExpectedSelectedFile;
    const selected_visible = state.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = selected_node }) orelse
        return error.ExpectedSelectedFile;
    state.viewer.tree_cursor = selected_visible;

    const FocusPalette = struct {
        pub fn get(_: @This(), role: theme.Role) ?theme.ColorValue {
            return switch (role) {
                .foreground => .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
                .accent => .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } },
                .muted => .{ .rgb = .{ .r = 7, .g = 8, .b = 9 } },
                .success => .{ .rgb = .{ .r = 10, .g = 11, .b = 12 } },
                .info => .{ .rgb = .{ .r = 13, .g = 14, .b = 15 } },
                .prompt => .{ .rgb = .{ .r = 16, .g = 17, .b = 18 } },
                .pane_cursor_bg => .{ .rgb = .{ .r = 19, .g = 20, .b = 21 } },
                else => null,
            };
        }
    };
    const palette = theme.Palette.fromConfig(FocusPalette{});
    const size: chasen.Size = .{ .width = 60, .height = 10 };
    const layout = bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    const directory_node = tree.nodeIndexForPath("dir", .all) orelse return error.ExpectedDirectory;
    const directory_visible = state.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = directory_node }) orelse
        return error.ExpectedDirectory;
    const added_node = tree.nodeIndexForPath("added.zig", .all) orelse return error.ExpectedAddedFile;
    const added_visible = state.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = added_node }) orelse
        return error.ExpectedAddedFile;
    const nested_node = tree.nodeIndexForPath("dir/nested.zig", .all) orelse return error.ExpectedNestedFile;
    const nested_visible = state.tree_projection.visibleIndexForTarget(tree, .{ .manifest_node = nested_node }) orelse
        return error.ExpectedNestedFile;
    const root_row = layout.header_rows;
    const directory_row = layout.header_rows + @as(u16, @intCast(directory_visible));
    const added_row = layout.header_rows + @as(u16, @intCast(added_visible));
    const nested_row = layout.header_rows + @as(u16, @intCast(nested_visible));
    const selected_row = layout.header_rows + @as(u16, @intCast(selected_visible));

    var active_surface: chasen.testing.TestSurface = undefined;
    try active_surface.init(size.width, size.height);
    defer active_surface.deinit();
    try view(.{ .page_state = &state, .palette = palette }, &active_surface.surface);
    try active_surface.expectCellText(0, 2, " ");
    try active_surface.expectCellText(1, 2, "F");
    const active_header = active_surface.surface.readCell(0, 2) orelse return error.ExpectedTreeHeader;
    const active_root = active_surface.surface.readCell(0, root_row) orelse return error.ExpectedRoot;
    const active_directory = active_surface.surface.readCell(4, directory_row) orelse return error.ExpectedDirectory;
    const active_added = active_surface.surface.readCell(4, added_row) orelse return error.ExpectedAddedFile;
    const active_nested = active_surface.surface.readCell(6, nested_row) orelse return error.ExpectedNestedFile;
    const active_selected = active_surface.surface.readCell(4, selected_row) orelse return error.ExpectedSelectedFile;
    const active_separator = active_surface.surface.readCell(layout.tree_width, 2) orelse return error.ExpectedTreeSeparator;
    try std.testing.expect(active_header.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(active_header.style.bold);
    try std.testing.expect(!active_header.style.dim);
    try std.testing.expect(active_root.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(active_root.style.bold);
    try std.testing.expect(!active_root.style.dim);
    try std.testing.expect(!active_root.style.reverse);
    try std.testing.expect(active_directory.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(active_directory.style.bold);
    try std.testing.expect(!active_directory.style.dim);
    try std.testing.expect(active_added.style.fg.eql(palette.color(.diff_added)));
    try std.testing.expect(!active_added.style.dim);
    try std.testing.expect(active_nested.style.fg.eql(palette.color(.foreground)));
    try std.testing.expect(!active_nested.style.dim);
    try std.testing.expect(active_selected.style.fg.eql(palette.color(.diff_modified)));
    try std.testing.expect(active_selected.style.bold);
    try std.testing.expect(!active_selected.style.reverse);
    try std.testing.expect(active_selected.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!active_selected.style.dim);
    const active_selected_trailing = active_surface.surface.readCell(layout.tree_width - 1, selected_row) orelse
        return error.ExpectedSelectedTrailingCell;
    try std.testing.expect(active_selected_trailing.style.fg.eql(palette.color(.diff_modified)));
    try std.testing.expect(active_selected_trailing.style.bold);
    try std.testing.expect(!active_selected_trailing.style.reverse);
    try std.testing.expect(active_selected_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!active_selected_trailing.style.dim);
    try std.testing.expect(active_separator.style.fg.eql(palette.color(.muted)));
    try std.testing.expect(active_separator.style.dim);
    try std.testing.expect(!active_separator.style.reverse);
    try std.testing.expect(!active_separator.style.bg.eql(palette.color(.pane_cursor_bg)));

    state.viewer.tree_cursor = 0;
    active_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &active_surface.surface);
    const selected_root = active_surface.surface.readCell(0, root_row) orelse return error.ExpectedRoot;
    const selected_root_trailing = active_surface.surface.readCell(layout.tree_width - 1, root_row) orelse return error.ExpectedRootTrailingCell;
    try std.testing.expect(selected_root.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(selected_root.style.bold);
    try std.testing.expect(!selected_root.style.reverse);
    try std.testing.expect(selected_root.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(selected_root_trailing.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(selected_root_trailing.style.bold);
    try std.testing.expect(!selected_root_trailing.style.reverse);
    try std.testing.expect(selected_root_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    state.viewer.tree_cursor = directory_visible;
    active_surface.surface.clearAll();
    try view(.{ .page_state = &state, .palette = palette }, &active_surface.surface);
    const selected_directory = active_surface.surface.readCell(4, directory_row) orelse return error.ExpectedDirectory;
    const selected_directory_trailing = active_surface.surface.readCell(layout.tree_width - 1, directory_row) orelse
        return error.ExpectedDirectoryTrailingCell;
    try std.testing.expect(selected_directory.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(selected_directory.style.bold);
    try std.testing.expect(!selected_directory.style.reverse);
    try std.testing.expect(selected_directory.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(selected_directory_trailing.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(selected_directory_trailing.style.bold);
    try std.testing.expect(!selected_directory_trailing.style.reverse);
    try std.testing.expect(selected_directory_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    state.viewer.tree_cursor = selected_visible;
    state.viewer.focus = .source;
    var inactive_surface: chasen.testing.TestSurface = undefined;
    try inactive_surface.init(size.width, size.height);
    defer inactive_surface.deinit();
    try view(.{ .page_state = &state, .palette = palette }, &inactive_surface.surface);
    try inactive_surface.expectCellText(0, 2, " ");
    try inactive_surface.expectCellText(1, 2, "F");
    const inactive_header = inactive_surface.surface.readCell(0, 2) orelse return error.ExpectedTreeHeader;
    const inactive_root = inactive_surface.surface.readCell(0, root_row) orelse return error.ExpectedRoot;
    const inactive_directory = inactive_surface.surface.readCell(4, directory_row) orelse return error.ExpectedDirectory;
    const inactive_added = inactive_surface.surface.readCell(4, added_row) orelse return error.ExpectedAddedFile;
    const inactive_nested = inactive_surface.surface.readCell(6, nested_row) orelse return error.ExpectedNestedFile;
    const inactive_selected = inactive_surface.surface.readCell(4, selected_row) orelse return error.ExpectedSelectedFile;
    const inactive_separator = inactive_surface.surface.readCell(layout.tree_width, 2) orelse return error.ExpectedTreeSeparator;
    try std.testing.expect(inactive_header.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(inactive_header.style.bold);
    try std.testing.expect(!inactive_header.style.dim);
    try std.testing.expect(inactive_root.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(inactive_root.style.bold);
    try std.testing.expect(!inactive_root.style.dim);
    try std.testing.expect(!inactive_root.style.reverse);
    try std.testing.expect(inactive_directory.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(inactive_directory.style.bold);
    try std.testing.expect(!inactive_directory.style.dim);
    try std.testing.expect(inactive_added.style.fg.eql(palette.color(.diff_added)));
    try std.testing.expect(!inactive_added.style.dim);
    try std.testing.expect(inactive_nested.style.fg.eql(palette.color(.foreground)));
    try std.testing.expect(!inactive_nested.style.dim);
    try std.testing.expect(inactive_selected.style.fg.eql(palette.color(.diff_modified)));
    try std.testing.expect(inactive_selected.style.bold);
    try std.testing.expect(!inactive_selected.style.dim);
    try std.testing.expect(!inactive_selected.style.reverse);
    try std.testing.expect(!inactive_selected.style.bg.eql(palette.color(.pane_cursor_bg)));
    const inactive_selected_trailing = inactive_surface.surface.readCell(layout.tree_width - 1, selected_row) orelse
        return error.ExpectedInactiveSelectedTrailingCell;
    try std.testing.expect(!inactive_selected_trailing.style.dim);
    try std.testing.expect(!inactive_selected_trailing.style.reverse);
    try std.testing.expect(!inactive_selected_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(inactive_separator.style.fg.eql(palette.color(.muted)));
    try std.testing.expect(inactive_separator.style.dim);
    try std.testing.expect(!inactive_separator.style.reverse);
    try std.testing.expect(!inactive_separator.style.bg.eql(palette.color(.pane_cursor_bg)));
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
        .authority = .accepted,
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
        .authority = .accepted,
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
        .authority = .accepted,
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
        .authority = .accepted,
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
        .authority = .accepted,
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

    const layout = bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    const geometry = state.sourceGeometry(size, state.currentSource().?);
    try std.testing.expectEqual(Msg.focus_source, state.mouseToMsg(.{ .col = layout.tree_width + 1, .row = geometry.body_first_row - 1 }, .left, size).?);
    try std.testing.expectEqual(
        Msg{ .mouse_source_press = .{ .col = 0, .row = geometry.body_first_row } },
        state.mouseToMsg(.{ .col = layout.tree_width + 1, .row = geometry.body_first_row }, .left, size).?,
    );
    try std.testing.expectEqual(Msg.mouse_source_wheel_down, state.mouseToMsg(.{ .col = layout.tree_width + 1, .row = geometry.body_first_row }, .wheel_down, size).?);

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

test "repository selection slice B live gesture fixes mode and resumes after leaving the pane" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "ABCDEFG\nHIJKLMN\nthird\nfourth\n");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const document = state.currentSource().?;
    const geometry = state.sourceGeometry(size, document);
    const first_row = geometry.body_first_row;

    state.source_search.mode = true;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = first_row } }, size);
    try std.testing.expect(!state.activeSourceSelection());
    state.source_search.mode = false;
    state.file_search.mode = true;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = first_row } }, size);
    try std.testing.expect(!state.activeSourceSelection());
    state.file_search.mode = false;

    // Separators are focus-only dead space and never create a selection.
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.separator_col.?, .row = first_row } }, size);
    try std.testing.expect(!state.activeSourceSelection());

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col + 3, .row = first_row } }, size);
    try std.testing.expect(state.activeSourceSelection());
    try std.testing.expectEqual(repository_selection.Mode.character, state.source_selection.?.mode);
    try std.testing.expectEqual(@as(usize, 3), state.source_selection.?.anchor.leading_byte);
    try std.testing.expectEqual(@as(usize, 4), state.source_selection.?.anchor.trailing_byte);

    _ = state.applyNavigation(allocator, .{ .mouse_source_drag = null }, size);
    try std.testing.expect(!state.source_selection.?.moved);
    _ = state.applyNavigation(allocator, .{ .mouse_source_drag = .{ .col = geometry.text_col + 4, .row = first_row + 1 } }, size);
    try std.testing.expect(state.source_selection.?.moved);
    try std.testing.expectEqual(@as(usize, 1), state.source_selection.?.focus.line_index);
    try std.testing.expectEqual(@as(usize, 5), state.source_selection.?.focus.trailing_byte);
    try std.testing.expectEqual(repository_selection.Mode.character, state.source_selection.?.mode);

    // A character drag entering its own gutter clamps to the leading logical
    // boundary; it does not switch to whole-line mode.
    _ = state.applyNavigation(allocator, .{ .mouse_source_drag = .{ .col = geometry.gutter_col, .row = first_row + 1 } }, size);
    try std.testing.expectEqual(repository_selection.Mode.character, state.source_selection.?.mode);
    try std.testing.expectEqual(@as(usize, 0), state.source_selection.?.focus.leading_byte);
    try std.testing.expectEqual(@as(usize, 0), state.source_selection.?.focus.trailing_byte);
    var character_release = state.applyNavigation(allocator, .{ .mouse_source_release = null }, size);
    defer character_release.deinit(allocator);
    try std.testing.expect(!state.activeSourceSelection());

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.gutter_col, .row = first_row } }, size);
    try std.testing.expectEqual(repository_selection.Mode.line, state.source_selection.?.mode);
    _ = state.applyNavigation(allocator, .{ .mouse_source_drag = .{ .col = geometry.text_col + 2, .row = first_row + 1 } }, size);
    try std.testing.expectEqual(repository_selection.Mode.line, state.source_selection.?.mode);
    try std.testing.expectEqual(@as(usize, 1), state.source_selection.?.focus.line_index);
    var line_release = state.applyNavigation(allocator, .{ .mouse_source_release = .{ .col = geometry.text_col + 2, .row = first_row + 1 } }, size);
    defer line_release.deinit(allocator);
    try std.testing.expect(!state.activeSourceSelection());

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.line_number_col, .row = first_row } }, size);
    try std.testing.expectEqual(repository_selection.Mode.line, state.source_selection.?.mode);
    state.cancelSourceSelection();
}

test "repository selection slice B hit testing applies scroll once and follows line number geometry" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "ABCDEFG\nHIJKLMN\nthird\nfourth\n");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const document = state.currentSource().?;
    var geometry = state.sourceGeometry(size, document);
    const first_row = geometry.body_first_row;

    state.viewer.source_horizontal_scroll = 2;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col + 1, .row = first_row } }, size);
    try std.testing.expectEqual(@as(usize, 3), state.source_selection.?.anchor.leading_byte);
    state.cancelSourceSelection();

    state.viewer.source_horizontal_scroll = 0;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col + 20, .row = first_row } }, size);
    try std.testing.expectEqual(@as(usize, "ABCDEFG".len), state.source_selection.?.anchor.leading_byte);
    try std.testing.expectEqual(@as(usize, "ABCDEFG".len), state.source_selection.?.anchor.trailing_byte);
    state.cancelSourceSelection();

    state.viewer.source_vertical_scroll = 1;
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = first_row } }, size);
    try std.testing.expectEqual(@as(usize, 1), state.source_selection.?.anchor.line_index);
    state.cancelSourceSelection();

    state.viewer.source_vertical_scroll = 0;
    state.viewer.source_horizontal_scroll = 0;
    _ = state.applyNavigation(allocator, .toggle_line_numbers, size);
    geometry = state.sourceGeometry(size, document);
    try std.testing.expectEqual(@as(u16, 1), geometry.text_col);
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = geometry.body_first_row } }, size);
    try std.testing.expectEqual(repository_selection.Mode.character, state.source_selection.?.mode);
    try std.testing.expectEqual(@as(usize, 0), state.source_selection.?.anchor.leading_byte);
}

test "repository selection slice B synthetic empty row rejects every gesture stage" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("empty.zig\x00", "");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const geometry = state.sourceGeometry(size, state.currentSource().?);

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.gutter_col, .row = geometry.body_first_row } }, size);
    try std.testing.expect(!state.activeSourceSelection());
    _ = state.applyNavigation(allocator, .{ .mouse_source_drag = .{ .col = geometry.text_col, .row = geometry.body_first_row } }, size);
    try std.testing.expect(!state.activeSourceSelection());
    var release = state.applyNavigation(allocator, .{ .mouse_source_release = .{ .col = geometry.text_col, .row = geometry.body_first_row } }, size);
    defer release.deinit(allocator);
    try std.testing.expect(!state.activeSourceSelection());
}

test "repository selection slice B owner replacement cancels live borrowed selection first" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("a.zig\x00b.zig\x00", "first\nsecond\n");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const geometry = state.sourceGeometry(size, state.currentSource().?);

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = geometry.body_first_row } }, size);
    try std.testing.expect(state.activeSourceSelection());
    state.viewer.focus = .tree;
    try std.testing.expect(state.applyNavigation(allocator, .move_down, size).selected_path_changed);
    try std.testing.expect(!state.activeSourceSelection());
    try std.testing.expect(state.displayed_document == null);

    state.repositoryChanged(allocator, 9, .{ .device = 10, .inode = 11 });
    try std.testing.expect(!state.activeSourceSelection());
    try std.testing.expect(state.bundle == null);
}

test "repository selection slice B accepted manifest and document replacement cancel live borrow" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "old source\n");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    var geometry = state.sourceGeometry(size, state.currentSource().?);

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = geometry.body_first_row } }, size);
    try std.testing.expect(state.activeSourceSelection());
    var incoming = try bundleForTest("main.zig\x00");
    var incoming_owned = true;
    defer if (incoming_owned) incoming.deinit(allocator);
    try state.replaceBundle(allocator, &incoming);
    incoming_owned = false;
    try std.testing.expect(!state.activeSourceSelection());

    geometry = state.sourceGeometry(size, state.currentSource().?);
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{ .col = geometry.text_col, .row = geometry.body_first_row } }, size);
    try std.testing.expect(state.activeSourceSelection());
    state.document_generation = 8;
    state.pending_document_generation = 8;
    // Byte-identical content still arrives in separately owned storage; Slice
    // B cancels before replacement rather than borrowing across that swap.
    const replacement_bytes = try allocator.dupe(u8, "old source\n");
    var replacement: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 8,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, state.selected_path.?),
        .value = .{ .source = try source_document.Document.initOwned(allocator, replacement_bytes, .init(replacement_bytes)) },
    };
    defer replacement.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &replacement));
    try std.testing.expect(!state.activeSourceSelection());
    try std.testing.expectEqualStrings("old source", state.currentSource().?.lineBody(0).?);
}

test "repository selection slice C moved release installs candidate and independent copy command" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "ABCDEFG\nHIJKLMN\n");
    defer state.deinit(allocator);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const geometry = state.sourceGeometry(size, state.currentSource().?);

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col + 3,
        .row = geometry.body_first_row,
    } }, size);
    _ = state.applyNavigation(allocator, .{ .mouse_source_drag = .{
        .col = geometry.text_col + 4,
        .row = geometry.body_first_row + 1,
    } }, size);
    var update = state.applyNavigation(allocator, .{ .mouse_source_release = null }, size);
    defer update.deinit(allocator);
    try std.testing.expect(!state.activeSourceSelection());
    try std.testing.expect(state.completed_selection != null);
    try std.testing.expectEqualStrings("DEFG\nHIJKL", state.completed_selection.?.text);
    var command = update.takeCommand() orelse return error.ExpectedSourceCopyCommand;
    defer command.deinit(allocator);
    switch (command) {
        .copy_source_selection => |text| {
            try std.testing.expectEqualStrings("DEFG\nHIJKL", text);
            text[0] = 'X';
            try std.testing.expectEqualStrings("DEFG\nHIJKL", state.completed_selection.?.text);
        },
    }

    // A later click changes cursor/focus only and retains the accepted owner.
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    var click = state.applyNavigation(allocator, .{ .mouse_source_release = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    defer click.deinit(allocator);
    try std.testing.expect(click.command == null);
    try std.testing.expectEqualStrings("DEFG\nHIJKL", state.completed_selection.?.text);
}

test "repository selection slice C first token to gutter keeps the token" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "ABC\n");
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);
    try std.testing.expectEqualStrings("ABC", state.completed_selection.?.text);
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    const geometry = state.sourceGeometry(size, state.currentSource().?);

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    _ = state.applyNavigation(allocator, .{ .mouse_source_drag = .{
        .col = geometry.gutter_col,
        .row = geometry.body_first_row,
    } }, size);
    var update = state.applyNavigation(allocator, .{ .mouse_source_release = null }, size);
    defer update.deinit(allocator);
    try std.testing.expectEqualStrings("A", state.completed_selection.?.text);
    switch (update.command.?) {
        .copy_source_selection => |text| try std.testing.expectEqualStrings("A", text),
    }
}

test "repository selection slice C candidate and clipboard allocation failures have separate terminals" {
    const backing = std.testing.allocator;
    const size: chasen.Size = .{ .width = 60, .height = 6 };

    {
        var state = try selectionStateForTest("main.zig\x00", "ABC\n");
        try installFirstLineCandidateForTest(&state, backing);
        const document = state.currentSource().?;
        const line = document.lineBody(0).?;
        var live = repository_selection.DragSelection.init(
            state.currentContentToken().?,
            .character,
            repository_selection.pointFromBoundary(0, 0),
        );
        live.update(repository_selection.pointFromBoundary(0, line.len));
        state.source_selection = live;
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
        defer state.deinit(failing.allocator());
        var update = state.applyNavigation(failing.allocator(), .{ .mouse_source_release = null }, size);
        defer update.deinit(failing.allocator());
        try std.testing.expect(update.command == null);
        try std.testing.expect(state.completed_selection == null);
        try std.testing.expect(!state.activeSourceSelection());
    }

    var observed_clipboard_failure = false;
    var fail_index: usize = 0;
    while (fail_index < 16 and !observed_clipboard_failure) : (fail_index += 1) {
        var state = try selectionStateForTest("main.zig\x00", "ABC\n");
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        defer state.deinit(failing.allocator());
        const document = state.currentSource().?;
        const line = document.lineBody(0).?;
        var live = repository_selection.DragSelection.init(
            state.currentContentToken().?,
            .character,
            repository_selection.pointFromBoundary(0, 0),
        );
        live.update(repository_selection.pointFromBoundary(0, line.len));
        state.source_selection = live;
        var update = state.applyNavigation(failing.allocator(), .{ .mouse_source_release = null }, size);
        defer update.deinit(failing.allocator());
        if (state.completed_selection != null and update.command == null) {
            observed_clipboard_failure = true;
            try std.testing.expectEqualStrings("ABC", state.completed_selection.?.text);
            try std.testing.expect(!state.activeSourceSelection());
        }
    }
    try std.testing.expect(observed_clipboard_failure);
}

test "repository selection slice C stale release clears prior candidate" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "ABC\n");
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);
    var token = state.currentContentToken().?;
    token.source_fingerprint = .init("different");
    var live = repository_selection.DragSelection.init(
        token,
        .line,
        repository_selection.pointFromLine(0),
    );
    live.moved = true;
    state.source_selection = live;

    var update = state.applyNavigation(allocator, .{ .mouse_source_release = null }, .{ .width = 60, .height = 6 });
    defer update.deinit(allocator);
    try std.testing.expect(update.command == null);
    try std.testing.expect(state.completed_selection == null);
    try std.testing.expect(!state.activeSourceSelection());
}

test "repository selection slice C real empty line keeps candidate without copy command" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "\nnext\n");
    defer state.deinit(allocator);
    var live = repository_selection.DragSelection.init(
        state.currentContentToken().?,
        .line,
        repository_selection.pointFromLine(0),
    );
    live.moved = true;
    state.source_selection = live;

    var update = state.applyNavigation(allocator, .{ .mouse_source_release = null }, .{ .width = 60, .height = 6 });
    defer update.deinit(allocator);
    try std.testing.expect(update.command == null);
    try std.testing.expect(state.completed_selection != null);
    try std.testing.expectEqualStrings("", state.completed_selection.?.text);
    try std.testing.expectEqualStrings("Selected source line is empty", state.status.text());
}

test "repository selection slice D reconciles accepted document and keeps other replacements fail closed" {
    const allocator = std.testing.allocator;
    const size: chasen.Size = .{ .width = 60, .height = 6 };

    {
        var state = try selectionStateForTest("main.zig\x00", "old source\n");
        defer state.deinit(allocator);
        try installFirstLineCandidateForTest(&state, allocator);
        state.repositoryChanged(allocator, 9, .{ .device = 10, .inode = 11 });
        try std.testing.expect(state.completed_selection == null);
    }
    {
        var state = try selectionStateForTest("a.zig\x00b.zig\x00", "old source\n");
        defer state.deinit(allocator);
        try installFirstLineCandidateForTest(&state, allocator);
        state.viewer.focus = .tree;
        const update = state.applyNavigation(allocator, .move_down, size);
        try std.testing.expect(update.selected_path_changed);
        try std.testing.expect(state.completed_selection == null);
    }
    {
        var state = try selectionStateForTest("main.zig\x00", "old source\n");
        defer state.deinit(allocator);
        try installFirstLineCandidateForTest(&state, allocator);
        var incoming = try bundleForTest("other.zig\x00");
        var incoming_owned = true;
        defer if (incoming_owned) incoming.deinit(allocator);
        try state.replaceBundle(allocator, &incoming);
        incoming_owned = false;
        try std.testing.expect(state.completed_selection == null);
    }

    // A different delivery generation and new allocation do not change the
    // semantic basis. Changed or inert source cannot retain the candidate.
    try expectDocumentReplacementCandidateForTest("old source\n", true);
    try expectDocumentReplacementCandidateForTest("changed source\n", false);
    try expectDocumentReplacementCandidateForTest(null, false);
}

test "repository selection slice D retains candidate across inactive page and presentation changes" {
    const allocator = std.testing.allocator;
    const size: chasen.Size = .{ .width = 60, .height = 6 };
    var state = try selectionStateForTest("main.zig\x00", "first\nneedle here\nthird\n");
    defer state.deinit(allocator);
    try installFirstLineCandidateForTest(&state, allocator);
    const retained_token = state.completed_selection.?.token.view();

    state.deactivate();
    try std.testing.expect(state.completed_selection != null);
    state.activate(state.repo_epoch, state.root_identity);
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));

    _ = state.applyNavigation(allocator, .focus_source, size);
    _ = state.applyNavigation(allocator, .source_last, size);
    _ = state.applyNavigation(allocator, .enter_source_search, size);
    for ("needle") |byte| _ = state.applyNavigation(allocator, .{ .source_search_insert = byte }, size);
    _ = state.applyNavigation(allocator, .submit_source_search, size);
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));

    state.syntax_generation = 8;
    state.pending_syntax_generation = 8;
    var syntax_finished = SyntaxFinished{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 8,
        .manifest_revision = state.manifest_revision,
        .source_revision = state.displayed_document.?.source_revision,
        .path = try allocator.dupe(u8, state.selected_path.?),
        .fingerprint = state.currentSource().?.fingerprint,
        .result = .unavailable,
    };
    defer syntax_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.unchanged, state.applySyntaxFinished(allocator, &syntax_finished));
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));

    state.displayed_document.?.change_decoration = .eligible;
    state.change_map_generation = 9;
    state.pending_change_map_generation = 9;
    var change_finished = ChangeMapFinished{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 9,
        .manifest_revision = state.manifest_revision,
        .source_revision = state.displayed_document.?.source_revision,
        .path = try allocator.dupe(u8, state.selected_path.?),
        .fingerprint = state.currentSource().?.fingerprint,
        .content_line_count = state.currentSource().?.contentLineCount(),
        .result = .unavailable,
    };
    defer change_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.unchanged, state.applyChangeMapFinished(allocator, &change_finished));
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));

    // Focus loss and resize cancel only a live borrow. The release-frozen
    // candidate is owned independently and survives both presentation events.
    const geometry = state.sourceGeometry(size, state.currentSource().?);
    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    try std.testing.expect(state.activeSourceSelection());
    _ = state.applyNavigation(allocator, .cancel_source_selection, size);
    try std.testing.expect(!state.activeSourceSelection());
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));

    _ = state.applyNavigation(allocator, .{ .mouse_source_press = .{
        .col = geometry.text_col,
        .row = geometry.body_first_row,
    } }, size);
    state.cancelSourceSelection();
    state.clampForBodySize(.{ .width = 50, .height = 5 });
    try std.testing.expect(!state.activeSourceSelection());
    try std.testing.expect(state.completed_selection.?.token.view().eql(retained_token));
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

test "repository accepted empty manifest renders the typed root at its mouse target" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest(""),
        .load_state = .empty,
    };
    defer state.deinit(allocator);

    const full_size = chasen.Size{ .width = 60, .height = 8 };
    var expanded_surface: chasen.testing.TestSurface = undefined;
    try expanded_surface.init(full_size.width, full_size.height);
    defer expanded_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/empty-repo" }, &expanded_surface.surface);
    try expanded_surface.expectCellText(0, 2, " ");
    try expanded_surface.expectCellText(1, 2, "F");
    try expanded_surface.expectCellText(0, 3, "▾");
    try expanded_surface.expectCellText(0, 4, "R");
    const expanded_snapshot = try expanded_surface.snapshot(allocator);
    defer allocator.free(expanded_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, expanded_snapshot, "Files") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded_snapshot, "▾ empty-repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded_snapshot, "Repository has no") != null);
    const expanded_layout = bodyLayout(full_size, state.viewer.tree_width, state.viewer.tree_hidden);
    const no_file_cell = expanded_surface.surface.readCell(expanded_layout.source_col + 1, repository_source_geometry.source_path_row) orelse
        return error.ExpectedNoFileSelectedCell;
    try std.testing.expect(no_file_cell.style.fg.eql(theme.Palette.default().color(.muted)));
    try std.testing.expect(!no_file_cell.style.dim);

    const root_click = state.mouseToMsg(.{ .col = 0, .row = 3 }, .left, full_size) orelse
        return error.ExpectedRootMouseTarget;
    try std.testing.expectEqual(Msg{ .mouse_toggle_row = 0 }, root_click);
    _ = state.applyNavigation(allocator, root_click, full_size);
    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.collapsed, state.tree_projection.root_disclosure);

    var collapsed_surface: chasen.testing.TestSurface = undefined;
    try collapsed_surface.init(full_size.width, full_size.height);
    defer collapsed_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/empty-repo" }, &collapsed_surface.surface);
    try collapsed_surface.expectCellText(0, 3, "▸");
    try collapsed_surface.expectCellText(0, 4, "R");

    const compact_size = chasen.Size{ .width = 60, .height = 3 };
    var compact_surface: chasen.testing.TestSurface = undefined;
    try compact_surface.init(compact_size.width, compact_size.height);
    defer compact_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/empty-repo" }, &compact_surface.surface);
    try compact_surface.expectCellText(0, 2, " ");
    try compact_surface.expectCellText(1, 2, "F");
    const compact_snapshot = try compact_surface.snapshot(allocator);
    defer allocator.free(compact_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, compact_snapshot, "empty-repo") == null);
    try std.testing.expectEqual(Msg.focus_tree, state.mouseToMsg(.{ .col = 0, .row = 2 }, .left, compact_size).?);

    var width_one: chasen.testing.TestSurface = undefined;
    try width_one.init(1, compact_size.height);
    defer width_one.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/empty-repo" }, &width_one.surface);
    try width_one.expectCellText(0, 2, " ");

    var width_two: chasen.testing.TestSurface = undefined;
    try width_two.init(2, compact_size.height);
    defer width_two.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/empty-repo" }, &width_two.surface);
    try width_two.expectCellText(0, 2, " ");
    try width_two.expectCellText(1, 2, "F");
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
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/gitframe" }, &test_surface.surface);
    const snapshot = try test_surface.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "▾ gitframe") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Loading selected file") != null);
    const non_selected_file = test_surface.surface.readCell(4, 6) orelse return error.ExpectedFileCell;
    try std.testing.expectEqual(theme.Palette.default().color(.foreground), non_selected_file.style.fg);
    const layout = bodyLayout(test_surface.surface.size(), state.viewer.tree_width, state.viewer.tree_hidden);
    try test_surface.expectCellText(
        layout.tree_width + 2,
        repository_source_geometry.source_body_first_row,
        "L",
    );
    const loading_cell = test_surface.surface.readCell(layout.source_col + 1, repository_source_geometry.source_body_first_row) orelse
        return error.ExpectedLoadingCheckpointCell;
    try std.testing.expect(loading_cell.style.fg.eql(theme.Palette.default().color(.muted)));
    try std.testing.expect(!loading_cell.style.dim);
    const inactive_path_cell = test_surface.surface.readCell(layout.source_col + 1, repository_source_geometry.source_path_row) orelse
        return error.ExpectedInactiveSourcePathCell;
    try std.testing.expect(inactive_path_cell.style.fg.eql(theme.Palette.default().color(.accent)));
    try std.testing.expect(!inactive_path_cell.style.dim);
    const source_rule = test_surface.surface.readCell(layout.tree_width + 1, repository_source_geometry.source_search_or_rule_row) orelse
        return error.ExpectedSourceHeaderRuleCell;
    try std.testing.expectEqualStrings("─", source_rule.char.grapheme);
    try std.testing.expect(source_rule.style.fg.eql(theme.Palette.default().color(.muted)));
    try std.testing.expect(source_rule.style.dim);

    state.viewer.tree_cursor = 0;
    _ = state.applyNavigation(std.testing.allocator, .toggle_directory, .{ .width = 60, .height = 10 });
    var collapsed_surface: chasen.testing.TestSurface = undefined;
    try collapsed_surface.init(60, 10);
    defer collapsed_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/gitframe" }, &collapsed_surface.surface);
    const collapsed_snapshot = try collapsed_surface.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(collapsed_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, collapsed_snapshot, "▸ gitframe") != null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed_snapshot, "README.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed_snapshot, "Loading selected file") != null);
}

test "repository page anchors inert checkpoint below source header rule" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("binary.dat\x00"),
        .load_state = .loaded,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    state.displayed_document = .{
        .path = try allocator.dupe(u8, state.selected_path.?),
        .manifest_revision = state.manifest_revision,
        .authority = .accepted,
        .value = .{ .inert = .binary },
    };

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(60, 8);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);

    const layout = bodyLayout(test_surface.surface.size(), state.viewer.tree_width, state.viewer.tree_hidden);
    try test_surface.expectCellText(
        layout.tree_width + 2,
        repository_source_geometry.source_body_first_row,
        "B",
    );
    const inert_cell = test_surface.surface.readCell(layout.source_col + 1, repository_source_geometry.source_body_first_row) orelse
        return error.ExpectedInertCheckpointCell;
    try std.testing.expect(inert_cell.style.fg.eql(theme.Palette.default().color(.muted)));
    try std.testing.expect(!inert_cell.style.dim);
    const source_rule = test_surface.surface.readCell(layout.tree_width + 1, repository_source_geometry.source_search_or_rule_row) orelse
        return error.ExpectedSourceHeaderRuleCell;
    try std.testing.expectEqualStrings("─", source_rule.char.grapheme);
    try std.testing.expect(source_rule.style.fg.eql(theme.Palette.default().color(.muted)));
    try std.testing.expect(source_rule.style.dim);
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
    state.viewer.focus = .source;
    _ = state.rebuildTreeProjection(null, false, 0);

    {
        var test_surface: chasen.testing.TestSurface = undefined;
        try test_surface.init(120, 8);
        defer test_surface.deinit();
        const palette: theme.Palette = .default();
        try view(.{ .page_state = &state, .palette = palette }, &test_surface.surface);
        try test_surface.expectCellText(0, 2, " ");
        try test_surface.expectCellText(1, 2, "F");
        const layout = bodyLayout(.{ .width = 120, .height = 8 }, state.viewer.tree_width, state.viewer.tree_hidden);
        const message_cell = test_surface.surface.readCell(0, layout.header_rows + 1) orelse
            return error.ExpectedChangedFilesMessage;
        try std.testing.expect(message_cell.style.fg.eql(palette.color(.muted)));
        try std.testing.expect(!message_cell.style.dim);
        const snapshot = try test_surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files [changed]") != null);
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
        // The Review-compatible default keeps the source pane usable instead
        // of widening for prose, so assert the distinct state label that is
        // guaranteed to fit and let the existing narrow matrix cover clipping.
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Changed-file status unavailable") != null);
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

    // At the minimum split width and five rows the full prose is clipped, but
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
        try test_surface.init(24, 5);
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
    const wide_layout = bodyLayout(wide, state.viewer.tree_width, state.viewer.tree_hidden);
    try std.testing.expectEqual(@as(u16, 28), wide_layout.tree_width);
    try std.testing.expectEqual(@as(u16, 3), wide_layout.header_rows);
    try std.testing.expectEqual(@as(u16, 7), wide_layout.treeRows(wide.height));
    try std.testing.expectEqual(Msg.focus_tree, state.mouseToMsg(.{ .col = 1, .row = 0 }, .left, wide).?);
    try std.testing.expect(state.mouseToMsg(.{ .col = wide_layout.tree_width, .row = 1 }, .left, wide) == null);
    try std.testing.expectEqual(Msg.focus_tree, state.mouseToMsg(.{ .col = 1, .row = 2 }, .left, wide).?);
    try std.testing.expectEqual(Msg{ .mouse_toggle_row = 0 }, state.mouseToMsg(.{ .col = 1, .row = 3 }, .left, wide).?);
    try std.testing.expectEqual(Msg{ .mouse_toggle_row = 1 }, state.mouseToMsg(.{ .col = 1, .row = 4 }, .left, wide).?);
    try std.testing.expectEqual(Msg{ .mouse_row = 2 }, state.mouseToMsg(.{ .col = 1, .row = 5 }, .left, wide).?);
    try std.testing.expectEqual(Msg.wheel_down, state.mouseToMsg(.{ .col = 1, .row = 0 }, .wheel_down, wide).?);

    const root_toggle = state.mouseToMsg(.{ .col = 1, .row = 3 }, .left, wide).?;
    _ = state.applyNavigation(std.testing.allocator, root_toggle, wide);
    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.collapsed, state.tree_projection.root_disclosure);
    _ = state.applyNavigation(std.testing.allocator, root_toggle, wide);
    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.expanded, state.tree_projection.root_disclosure);

    const narrow = chasen.Size{ .width = 20, .height = 6 };
    try std.testing.expectEqual(narrow.width, bodyLayout(narrow, state.viewer.tree_width, state.viewer.tree_hidden).tree_width);
    try std.testing.expectEqual(Msg{ .mouse_row = 2 }, state.mouseToMsg(.{ .col = 19, .row = 5 }, .left, narrow).?);
}

test "repository tree width controls share rendering mouse and source geometry" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "one\ntwo\n");
    defer state.deinit(allocator);
    state.viewer.focus = .source;

    const size = chasen.Size{ .width = 104, .height = 10 };
    try std.testing.expectEqual(@as(u16, 34), bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden).tree_width);

    _ = state.applyNavigation(allocator, .decrease_tree_width, size);
    try std.testing.expectEqual(@as(?u16, 30), state.viewer.tree_width);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqualStrings("main.zig", state.selected_path.?);

    const adjusted = bodyLayout(size, state.viewer.tree_width, state.viewer.tree_hidden);
    try std.testing.expectEqual(@as(u16, 30), adjusted.tree_width);
    try std.testing.expectEqual(@as(u16, 73), state.sourceGeometry(size, state.currentSource().?).width);
    try std.testing.expect(state.mouseToMsg(.{ .col = adjusted.tree_width, .row = 0 }, .left, size) == null);
    try std.testing.expectEqual(
        Msg.focus_source,
        state.mouseToMsg(.{ .col = adjusted.tree_width + 1, .row = 0 }, .left, size).?,
    );
    try std.testing.expectEqual(
        BodyPoint{ .col = 4, .row = 2 },
        sourceGesturePoint(.{ .col = adjusted.tree_width + 1 + 4, .row = 2 }, size, state.viewer.tree_width, state.viewer.tree_hidden).?,
    );

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(size.width, size.height);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default(), .repo_root = "/work/gitframe" }, &test_surface.surface);
    try test_surface.expectCellText(adjusted.tree_width, 0, "│");

    _ = state.applyNavigation(allocator, .increase_tree_width, size);
    try std.testing.expectEqual(@as(?u16, 34), state.viewer.tree_width);
}

test "repository transition B1 incoming lifecycle keeps one destination owner" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 4,
        .root_identity = identity,
        .selected_path = "retained.zig",
    };
    defer state.deinit(allocator);

    var location = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "target.zig", .line = 9 } },
    );
    state.acceptIncoming(allocator, &location);
    try std.testing.expect(state.incomingIsPending());
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);

    state.deactivate();
    try std.testing.expect(state.incomingIsPending());
    state.activate(4, identity);
    try std.testing.expect(state.incomingIsPending());
    state.requestReload(true);
    try std.testing.expect(state.incomingIsPending());

    _ = state.applyNavigation(allocator, .toggle_line_numbers, .{ .width = 80, .height = 10 });
    try std.testing.expect(state.incomingIsPending());
    _ = state.applyNavigation(allocator, .cancel_file_search, .{ .width = 80, .height = 10 });
    try std.testing.expect(state.incomingIsPending());

    _ = state.applyNavigation(allocator, .move_down, .{ .width = 80, .height = 10 });
    try std.testing.expect(!state.incomingIsPending());
    try std.testing.expect(state.incomingUnavailable() == null);
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);

    var unavailable = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .unavailable = .{ .path = "deleted.zig", .reason = .no_current_path } },
    );
    state.acceptIncoming(allocator, &unavailable);
    try std.testing.expectEqualStrings("deleted.zig", state.incomingUnavailable().?.path);
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);

    var successor = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "successor.zig", .line = null } },
    );
    state.acceptIncoming(allocator, &successor);
    try std.testing.expect(state.incomingIsPending());
    try std.testing.expectEqualStrings("successor.zig", state.incoming.awaiting_manifest.path);

    state.repositoryChanged(allocator, 8, .{ .device = 13, .inode = 21 });
    try std.testing.expect(!state.incomingIsPending());
    try std.testing.expect(state.incomingUnavailable() == null);
    try std.testing.expect(state.selected_path == null);
}

test "repository transition B1 direct unavailable renders byte-safe terminal" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("retained.zig\x00"),
        .load_state = .loaded,
        .repo_epoch = 4,
        .root_identity = identity,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    const raw_path = [_]u8{ 'o', 'l', 'd', '/', 0xff };
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .unavailable = .{ .path = &raw_path, .reason = .no_current_path } },
    );
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expectEqualSlices(u8, &raw_path, state.incomingUnavailable().?.path);
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);

    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(80, 6);
    defer test_surface.deinit();
    try view(.{ .page_state = &state, .palette = .default() }, &test_surface.surface);
    const snapshot = try test_surface.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Repository target unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, page_link.RepositoryUnavailableReason.no_current_path.message()) != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "retained.zig") == null);

    _ = state.applyNavigation(allocator, .toggle_line_numbers, .{ .width = 80, .height = 6 });
    try std.testing.expect(state.incomingUnavailable() != null);
    _ = state.applyNavigation(allocator, .tree_first, .{ .width = 80, .height = 6 });
    try std.testing.expect(state.incomingUnavailable() == null);
}

test "repository transition B2a resolves exact retained manifest through All and collapsed ancestors" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("dir/target.zig\x00changed.zig\x00retained.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
        .file_visibility = .changed,
    };
    defer state.deinit(allocator);
    try applyBundleStatusForTest(&state.bundle.?, " M changed.zig\x00");
    state.bundle.?.tree.nodes[state.bundle.?.tree.nodeIndexForPath("dir", .all).?].expanded = false;
    state.bundle.?.tree.rebuildVisibleFor(.changed);
    state.selected_path = state.bundle.?.tree.filePath("changed.zig", .changed);
    state.all_selection_anchor = try allocator.dupe(u8, "retained.zig");
    state.tree_projection.root_disclosure = .collapsed;
    state.viewer.tree_cursor = 0;

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "dir/target.zig", .line = 9 } },
    );
    const owned_address = @intFromPtr(incoming.location.path.ptr);
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator));

    try std.testing.expect(state.incoming == .awaiting_document);
    const pending = state.incoming.documentIntent().?;
    try std.testing.expectEqual(owned_address, @intFromPtr(pending.location.path.ptr));
    try std.testing.expectEqual(@as(u64, 6), pending.manifest_revision);
    try std.testing.expectEqual(@as(?u32, 9), pending.location.line);
    try std.testing.expectEqualStrings("dir/target.zig", state.selected_path.?);
    try std.testing.expectEqual(repository_tree.Visibility.all, state.file_visibility);
    try std.testing.expect(state.all_selection_anchor == null);
    try std.testing.expectEqual(repository_tree_projection.RootDisclosure.expanded, state.tree_projection.root_disclosure);
    try std.testing.expect(state.bundle.?.tree.nodes[state.bundle.?.tree.nodeIndexForPath("dir", .all).?].expanded);
    const selected_target = state.tree_projection.targetAt(&state.bundle.?.tree, state.viewer.tree_cursor) orelse
        return error.ExpectedSelectedTarget;
    switch (selected_target) {
        .repo_root => return error.ExpectedFileTarget,
        .manifest_node => |node_index| try std.testing.expectEqualStrings(
            "dir/target.zig",
            state.bundle.?.tree.nodes[node_index].path,
        ),
    }
    try std.testing.expect(state.needs_document_revalidation);
    try std.testing.expectEqualStrings("Review target opened in All files", state.status.text());
}

test "repository transition B2a exact failures retain prior browser location" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .active = true,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("retained.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    var missing = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "missing.zig", .line = null } },
    );
    state.acceptIncoming(allocator, &missing);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator));
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.path_not_found, state.incomingUnavailable().?.reason);
    try std.testing.expectEqualStrings("missing.zig", state.incomingUnavailable().?.path);
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);

    var wrong_repository = try page_link.RepositoryIncoming.initOwned(
        allocator,
        9,
        identity,
        .{ .location = .{ .path = "retained.zig", .line = 1 } },
    );
    state.acceptIncoming(allocator, &wrong_repository);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator));
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.request_failed, state.incomingUnavailable().?.reason);
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);
}

test "repository transition B2a first owner install waits for activation identity" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .bundle = try bundleForTest("retained.zig\x00target.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "target.zig", .line = 3 } },
    );
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expect(state.incomingUnavailable() == null);
    try std.testing.expectEqualStrings("retained.zig", state.selected_path.?);

    state.activate(4, identity);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqualStrings("target.zig", state.selected_path.?);
    try std.testing.expectEqual(@as(?u32, 3), state.incoming.documentIntent().?.location.line);
}

test "repository transition B2a resolves or terminalizes matching manifest completion" {
    const allocator = std.testing.allocator;
    const identity: root_capability.Identity = .{ .device = 3, .inode = 5 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = identity,
        .generation = 7,
        .pending_generation = 7,
        .load_state = .loading,
    };
    defer state.deinit(allocator);

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "src/main.zig", .line = null } },
    );
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.incoming == .awaiting_manifest);

    var finished: ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = 4, .activation_id = 2 },
        .root_identity = identity,
        .generation = 7,
        .result = .{ .loaded = try bundleForTest("README.md\x00src/main.zig\x00") },
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &finished));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqualStrings("src/main.zig", state.selected_path.?);
    try std.testing.expectEqual(@as(u64, 1), state.incoming.documentIntent().?.manifest_revision);
    try std.testing.expect(state.needs_document_revalidation);

    state.dismissIncoming(allocator);
    state.generation = 8;
    state.pending_generation = 8;
    var failed_incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        4,
        identity,
        .{ .location = .{ .path = "src/main.zig", .line = null } },
    );
    state.incoming.accept(allocator, &failed_incoming);
    var failed: ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = 4, .activation_id = 2 },
        .root_identity = identity,
        .generation = 8,
        .result = .{ .failed_static = "manifest failed" },
    };
    defer failed.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyFinished(allocator, &failed));
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.request_failed, state.incomingUnavailable().?.reason);
}

test "repository accepted current source excludes retained revalidation authority" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "one\ntwo\n");
    defer state.deinit(allocator);
    state.freshness = .fresh;

    try std.testing.expect(state.acceptedCurrentSourceForSelection() != null);

    state.needs_revalidation = true;
    try std.testing.expect(state.currentSource() != null);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.needs_revalidation = false;

    state.needs_document_revalidation = true;
    try std.testing.expect(state.currentSource() != null);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.needs_document_revalidation = false;

    state.pending_generation = 9;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.pending_generation = null;

    state.pending_document_generation = 11;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.pending_document_generation = null;

    state.freshness = .validating;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.freshness = .fresh;

    state.active = false;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.active = true;

    state.activation_id = 0;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.activation_id = 2;

    const root_identity = state.root_identity.?;
    state.root_identity = null;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.root_identity = root_identity;

    state.displayed_document.?.authority = .revalidation_required;
    try std.testing.expect(state.currentSource() != null);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
    state.displayed_document.?.authority = .accepted;

    state.displayed_document.?.manifest_revision += 1;
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
}

test "repository accepted source authority requires a matching completion after spawn rejection" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("main.zig\x00", "old source\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;

    try std.testing.expect(state.acceptedCurrentSourceForSelection() != null);
    state.requireDocumentRevalidation();
    try std.testing.expect(state.currentSource() != null);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);

    var rejected_request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer rejected_request.deinit(allocator);
    try std.testing.expectEqual(
        DisplayedDocument.Authority.revalidation_required,
        state.displayed_document.?.authority,
    );
    state.rejectDocumentSpawn(rejected_request.generation);
    try std.testing.expect(state.pending_document_generation == null);
    try std.testing.expect(!state.needs_document_revalidation);
    try std.testing.expect(state.currentSource() != null);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);

    // A later explicit retry may schedule work, but scheduling alone still
    // cannot promote the retained bytes.
    state.requireDocumentRevalidation();
    var accepted_request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer accepted_request.deinit(allocator);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);

    const replacement = try allocator.dupe(u8, "accepted replacement\n");
    var finished: DocumentFinished = .{
        .identity = accepted_request.identity,
        .root_identity = root.capability.identity,
        .generation = accepted_request.generation,
        .manifest_revision = accepted_request.manifest_revision,
        .path = try allocator.dupe(u8, accepted_request.path),
        .value = .{ .source = try source_document.Document.initOwned(
            allocator,
            replacement,
            .init(replacement),
        ) },
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    try std.testing.expectEqual(
        DisplayedDocument.Authority.accepted,
        state.displayed_document.?.authority,
    );
    try std.testing.expect(state.acceptedCurrentSourceForSelection() != null);
}

fn fileSearchDocumentFinishedForTest(
    allocator: std.mem.Allocator,
    request: *const DocumentRequest,
    content: ?[]const u8,
) !DocumentFinished {
    var value: DocumentValue = if (content) |source| blk: {
        const bytes = try allocator.dupe(u8, source);
        errdefer allocator.free(bytes);
        break :blk .{ .source = try source_document.Document.initOwned(
            allocator,
            bytes,
            .init(bytes),
        ) };
    } else .{ .inert = .binary };
    errdefer switch (value) {
        .source => |*document| document.deinit(allocator),
        .inert => {},
    };
    return .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .path = try allocator.dupe(u8, request.path),
        .value = value,
    };
}

test "repository file search focus uses an already accepted same-path source immediately" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("alpha.zig\x00beta.zig\x00", "accepted source\n");
    defer state.deinit(allocator);
    state.freshness = .fresh;
    state.viewer.focus = .tree;
    const size: chasen.Size = .{ .width = 80, .height = 10 };

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);

    try std.testing.expectEqualStrings("alpha.zig", state.selected_path.?);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expect(state.file_search_source_focus == .none);
    try std.testing.expect(state.pending_document_request == null);
}

test "repository file search focus binds a prepared successor and consumes accepted source" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("alpha.zig\x00beta.zig\x00", "old alpha\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;
    const size: chasen.Size = .{ .width = 80, .height = 10 };

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .file_search_next, size);
    var update = state.applyNavigation(allocator, .submit_file_search, size);
    defer update.deinit(allocator);

    try std.testing.expect(update.selected_path_changed);
    try std.testing.expectEqualStrings("beta.zig", state.selected_path.?);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expect(state.currentSource() == null);
    try std.testing.expect(state.file_search_source_focus.awaitingRequest() != null);

    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    try std.testing.expectEqual(
        request.generation,
        state.file_search_source_focus.awaitingGeneration().?.generation,
    );
    try std.testing.expectEqual(
        request.generation,
        state.pending_document_request.?.generation,
    );

    var finished = try fileSearchDocumentFinishedForTest(allocator, &request, "accepted beta\n");
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqualStrings("accepted beta\n", state.currentSource().?.bytes);
    try std.testing.expect(state.file_search_source_focus == .none);
    try std.testing.expect(state.pending_document_request == null);
}

test "repository file search focus directly binds an exact pending request" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("main.zig\x00", "last good\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;
    state.requireDocumentRevalidation();

    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    const size: chasen.Size = .{ .width = 80, .height = 10 };
    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);

    try std.testing.expectEqual(
        request.generation,
        state.file_search_source_focus.awaitingGeneration().?.generation,
    );
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);

    var stale = try fileSearchDocumentFinishedForTest(allocator, &request, "stale\n");
    stale.generation -|= 1;
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale));
    try std.testing.expectEqual(
        request.generation,
        state.file_search_source_focus.awaitingGeneration().?.generation,
    );
    try std.testing.expectEqual(@as(?u64, request.generation), state.pending_document_generation);

    var accepted = try fileSearchDocumentFinishedForTest(allocator, &request, "accepted\n");
    defer accepted.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &accepted));
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expect(state.file_search_source_focus == .none);
}

test "repository file search focus rejects an incompatible pending request basis" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("main.zig\x00", "last good\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;
    state.requireDocumentRevalidation();

    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    const size: chasen.Size = .{ .width = 80, .height = 10 };
    const exact = state.pending_document_request.?;
    var mismatches = [_]repository_file_search_focus.PendingDocumentRequest{ exact, exact, exact, exact };
    mismatches[0].basis.activation_id +%= 1;
    mismatches[1].basis.root_identity.inode +%= 1;
    mismatches[2].basis.manifest_revision +%= 1;
    mismatches[3].basis.path = "other.zig";
    for (mismatches) |mismatch| {
        state.pending_document_request = mismatch;
        _ = state.applyNavigation(allocator, .enter_file_search, size);
        _ = state.applyNavigation(allocator, .submit_file_search, size);

        try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
        try std.testing.expect(state.file_search_source_focus == .none);
        try std.testing.expectEqual(@as(?u64, request.generation), state.pending_document_generation);
    }

    state.pending_document_request = exact;
    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expectEqual(
        request.generation,
        state.file_search_source_focus.awaitingGeneration().?.generation,
    );
}

test "repository file search focus clears borrowed intent on selection reload and deactivation" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("alpha.zig\x00beta.zig\x00", "alpha\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;
    const size: chasen.Size = .{ .width = 80, .height = 10 };

    _ = state.applyNavigation(allocator, .enter_file_search, size);
    _ = state.applyNavigation(allocator, .file_search_next, size);
    _ = state.applyNavigation(allocator, .submit_file_search, size);
    try std.testing.expect(state.file_search_source_focus.awaitingRequest() != null);

    _ = state.applyNavigation(allocator, .move_up, size);
    try std.testing.expectEqualStrings("alpha.zig", state.selected_path.?);
    try std.testing.expect(state.file_search_source_focus == .none);

    state.file_search_source_focus.awaitDocumentRequest(state.currentFileSearchFocusBasis().?);
    state.requestReload(true);
    try std.testing.expect(state.file_search_source_focus == .none);
    try std.testing.expect(state.pending_document_request == null);

    state.file_search_source_focus.awaitDocumentRequest(state.currentFileSearchFocusBasis().?);
    state.deactivate();
    try std.testing.expect(state.file_search_source_focus == .none);
}

test "repository file search focus closes preparation spawn and inert terminals" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    const size: chasen.Size = .{ .width = 80, .height = 10 };

    {
        var state = try selectionStateForTest("alpha.zig\x00beta.zig\x00", "alpha\n");
        defer state.deinit(allocator);
        state.root_identity = root.capability.identity;
        state.freshness = .fresh;
        _ = state.applyNavigation(allocator, .enter_file_search, size);
        _ = state.applyNavigation(allocator, .file_search_next, size);
        _ = state.applyNavigation(allocator, .submit_file_search, size);
        try std.testing.expect(state.file_search_source_focus.awaitingRequest() != null);

        state.markDocumentRequestPreparationFailed(error.OutOfMemory);
        try std.testing.expect(state.file_search_source_focus == .none);
        try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    }

    {
        var state = try selectionStateForTest("alpha.zig\x00beta.zig\x00", "alpha\n");
        defer state.deinit(allocator);
        state.root_identity = root.capability.identity;
        state.freshness = .fresh;
        _ = state.applyNavigation(allocator, .enter_file_search, size);
        _ = state.applyNavigation(allocator, .file_search_next, size);
        _ = state.applyNavigation(allocator, .submit_file_search, size);
        var request = try state.prepareDocumentRequest(allocator, &root.capability);
        defer request.deinit(allocator);
        state.rejectDocumentSpawn(request.generation);
        try std.testing.expect(state.file_search_source_focus == .none);
        try std.testing.expect(state.pending_document_request == null);
        try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    }

    {
        var state = try selectionStateForTest("alpha.zig\x00beta.zig\x00", "alpha\n");
        defer state.deinit(allocator);
        state.root_identity = root.capability.identity;
        state.freshness = .fresh;
        _ = state.applyNavigation(allocator, .enter_file_search, size);
        _ = state.applyNavigation(allocator, .file_search_next, size);
        _ = state.applyNavigation(allocator, .submit_file_search, size);
        var request = try state.prepareDocumentRequest(allocator, &root.capability);
        defer request.deinit(allocator);
        var inert = try fileSearchDocumentFinishedForTest(allocator, &request, null);
        defer inert.deinit(allocator);
        try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &inert));
        try std.testing.expect(state.file_search_source_focus == .none);
        try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
        try std.testing.expect(state.displayed_document.?.value == .inert);
    }
}

test "repository capability terminal cannot promote retained source authority" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "retained source\n");
    defer state.deinit(allocator);
    state.freshness = .fresh;

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = null } },
    );
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.requireDocumentRevalidation();
    state.markDocumentCapabilityUnavailable();

    try std.testing.expectEqual(
        page_link.RepositoryUnavailableReason.request_failed,
        state.incomingUnavailable().?.reason,
    );
    try std.testing.expect(!state.needs_document_revalidation);
    try std.testing.expect(state.currentSource() != null);
    try std.testing.expect(state.acceptedCurrentSourceForSelection() == null);
}

test "repository transition B2b1 resolves an already accepted source without a task" {
    const allocator = std.testing.allocator;
    var state = try selectionStateForTest("main.zig\x00", "one\ntwo\nthree\n");
    defer state.deinit(allocator);
    state.freshness = .fresh;
    const source_address = @intFromPtr(state.currentSource().?);
    const cases = [_]struct { line: u32, cursor: usize }{
        .{ .line = 1, .cursor = 0 },
        .{ .line = 2, .cursor = 1 },
        .{ .line = 99, .cursor = 2 },
    };
    for (cases) |case| {
        state.viewer.focus = .tree;
        var incoming = try page_link.RepositoryIncoming.initOwned(
            allocator,
            state.repo_epoch,
            state.root_identity.?,
            .{ .location = .{ .path = "main.zig", .line = case.line } },
        );
        state.acceptIncoming(allocator, &incoming);
        try std.testing.expect(state.resolveIncomingAfterActivation(allocator));
        try std.testing.expect(state.incoming == .none);
        try std.testing.expectEqual(source_address, @intFromPtr(state.currentSource().?));
        try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
        try std.testing.expectEqual(case.cursor, state.viewer.source_cursor);
        try std.testing.expectEqual(case.cursor, state.viewer.source_vertical_scroll);
        try std.testing.expect(!state.needs_document_revalidation);
    }

    state.viewer.focus = .tree;
    state.viewer.source_cursor = 1;
    state.viewer.source_vertical_scroll = 1;
    var path_only = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = null } },
    );
    state.acceptIncoming(allocator, &path_only);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator));
    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_vertical_scroll);
}

fn expectReactivatedIncomingDocumentForTest(
    line: ?u32,
    replacement_source: ?[]const u8,
    expected_cursor: ?usize,
) !void {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("main.zig\x00", "old one\nold two\nold three\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;
    state.viewer.focus = .tree;
    state.viewer.source_cursor = 1;
    state.viewer.source_vertical_scroll = 1;

    state.deactivate();
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = line } },
    );
    state.acceptIncoming(allocator, &incoming);
    state.activate(state.repo_epoch, root.capability.identity);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expect(state.needs_revalidation);
    try std.testing.expect(!state.needs_document_revalidation);
    try std.testing.expectEqual(repository_model.Focus.tree, state.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_vertical_scroll);

    var manifest_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer manifest_request.deinit(allocator);
    var manifest_finished: ManifestFinished = .{
        .identity = manifest_request.identity,
        .root_identity = manifest_request.root.identity,
        .generation = manifest_request.generation,
        .result = .{ .unchanged = state.bundle.?.document.fingerprint },
    };
    defer manifest_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.unchanged, state.applyFinished(allocator, &manifest_finished));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expect(state.needs_document_revalidation);

    var document_request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer document_request.deinit(allocator);
    const value: DocumentValue = if (replacement_source) |content| blk: {
        const bytes = try allocator.dupe(u8, content);
        break :blk .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) };
    } else .{ .inert = .binary };
    var document_finished: DocumentFinished = .{
        .identity = document_request.identity,
        .root_identity = document_request.root.identity,
        .generation = document_request.generation,
        .manifest_revision = document_request.manifest_revision,
        .path = try allocator.dupe(u8, document_request.path),
        .value = value,
    };
    defer document_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &document_finished));

    if (expected_cursor) |cursor| {
        try std.testing.expect(state.incoming == .none);
        try std.testing.expectEqual(cursor, state.viewer.source_cursor);
        try std.testing.expectEqual(cursor, state.viewer.source_vertical_scroll);
        try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
        try std.testing.expectEqualStrings(replacement_source.?, state.currentSource().?.bytes);
    } else {
        try std.testing.expectEqual(
            page_link.RepositoryUnavailableReason.source_unavailable,
            state.incomingUnavailable().?.reason,
        );
        try std.testing.expect(state.displayed_document.?.value == .inert);
    }
}

test "repository transition B2b1 reactivation waits for current source authority" {
    try expectReactivatedIncomingDocumentForTest(2, "new one\nnew two\nnew three\n", 1);
    try expectReactivatedIncomingDocumentForTest(null, "new one\nnew two\nnew three\n", 0);
    try expectReactivatedIncomingDocumentForTest(2, null, null);
}

fn expectIncomingDocumentLineForTest(
    content: []const u8,
    line: ?u32,
    expected_cursor: usize,
    inactive_completion: bool,
) !void {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = root.capability.identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = line } },
    );
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expect(state.wantsDocumentRequest());

    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    try std.testing.expectEqual(
        @as(?u64, request.generation),
        state.incoming.documentIntent().?.document_generation,
    );
    if (inactive_completion) state.deactivate();
    const bytes = try allocator.dupe(u8, content);
    var finished: DocumentFinished = .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .path = try allocator.dupe(u8, request.path),
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(expected_cursor, state.viewer.source_cursor);
    try std.testing.expectEqual(expected_cursor, state.viewer.source_vertical_scroll);
    try std.testing.expectEqual(repository_model.Focus.source, state.viewer.focus);
    try std.testing.expectEqual(!inactive_completion, state.active);
}

test "repository transition B2b1 binds completion and clamps current source lines" {
    try expectIncomingDocumentLineForTest("one\ntwo\nthree\n", null, 0, false);
    try expectIncomingDocumentLineForTest("one\ntwo\nthree\n", 1, 0, false);
    try expectIncomingDocumentLineForTest("one\ntwo\nthree\n", 2, 1, false);
    try expectIncomingDocumentLineForTest("one\ntwo\nthree\n", 99, 2, true);
    try expectIncomingDocumentLineForTest("", 99, 0, false);
}

test "repository transition B2b1 inert document moves request path to unavailable" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = root.capability.identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = 1 } },
    );
    const owned_address = @intFromPtr(incoming.location.path.ptr);
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator));
    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    var finished: DocumentFinished = .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .path = try allocator.dupe(u8, request.path),
        .value = .{ .inert = .binary },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    const unavailable = state.incomingUnavailable().?;
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.source_unavailable, unavailable.reason);
    try std.testing.expectEqual(owned_address, @intFromPtr(unavailable.path.ptr));
    try std.testing.expectEqualStrings("main.zig", state.selected_path.?);
    try std.testing.expect(state.displayed_document.?.value == .inert);
}

test "repository transition B2b1 wrong root terminalizes the bound owner" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 4,
        .root_identity = root.capability.identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 6,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = 1 } },
    );
    const owned_address = @intFromPtr(incoming.location.path.ptr);
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.resolveIncomingAfterActivation(allocator));
    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    const bytes = try allocator.dupe(u8, "source\n");
    var finished: DocumentFinished = .{
        .identity = request.identity,
        .root_identity = .{
            .device = request.root.identity.device,
            .inode = request.root.identity.inode +% 1,
        },
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .path = try allocator.dupe(u8, request.path),
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };
    defer finished.deinit(allocator);

    try std.testing.expectEqual(ApplyOutcome.failed, state.applyDocumentFinished(allocator, &finished));
    const unavailable = state.incomingUnavailable().?;
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.request_failed, unavailable.reason);
    try std.testing.expectEqual(owned_address, @intFromPtr(unavailable.path.ptr));
    try std.testing.expect(state.displayed_document == null);
}

fn acceptIncomingFailureOwnerForTest(
    state: *RepositoryPageState,
    allocator: std.mem.Allocator,
    path: []const u8,
) !usize {
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = path, .line = 2 } },
    );
    const owned_address = @intFromPtr(incoming.location.path.ptr);
    state.acceptIncoming(allocator, &incoming);
    return owned_address;
}

fn expectIncomingRequestFailureForTest(state: *const RepositoryPageState, owned_address: usize) !void {
    const unavailable = state.incomingUnavailable().?;
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.request_failed, unavailable.reason);
    try std.testing.expectEqual(owned_address, @intFromPtr(unavailable.path.ptr));
}

test "repository transition B2b2a manifest start failures close the owner" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = .{ .device = 5, .inode = 6 },
        .needs_revalidation = true,
    };
    defer state.deinit(allocator);

    const preparation_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "manifest-preparation.zig");
    state.markRequestPreparationFailed(error.OutOfMemory);
    try expectIncomingRequestFailureForTest(&state, preparation_address);

    const spawn_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "manifest-spawn.zig");
    state.pending_generation = 8;
    state.rejectSpawn(7);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(@as(?u64, 8), state.pending_generation);
    state.rejectSpawn(8);
    try expectIncomingRequestFailureForTest(&state, spawn_address);
    try std.testing.expect(state.pending_generation == null);

    const predecessor_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "predecessor.zig");
    state.generation = 13;
    state.pending_generation = 13;
    state.requestReload(true);
    state.markRequestPreparationFailed(error.OutOfMemory);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(@as(?u64, 13), state.pending_generation);
    try std.testing.expectEqual(predecessor_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));
    var predecessor_finished: ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 13,
        .result = .{ .loaded = try bundleForTest("predecessor.zig\x00") },
    };
    defer predecessor_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &predecessor_finished));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqual(predecessor_address, @intFromPtr(state.incoming.documentIntent().?.location.path.ptr));

    const missing_repository_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "missing-repository.zig");
    state.requestReload(false);
    try expectIncomingRequestFailureForTest(&state, missing_repository_address);
    try std.testing.expectEqual(LoadState.no_repository, state.load_state);
}

test "repository transition B2b2a document start failures close the bound owner" {
    const allocator = std.testing.allocator;
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = .{ .device = 5, .inode = 6 },
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 9,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();

    const preparation_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.markDocumentRequestPreparationFailed(error.OutOfMemory);
    try expectIncomingRequestFailureForTest(&state, preparation_address);

    const spawn_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.document_generation = 12;
    state.pending_document_generation = 12;
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 12));
    state.rejectDocumentSpawn(11);
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqual(@as(?u64, 12), state.pending_document_generation);
    state.rejectDocumentSpawn(12);
    try expectIncomingRequestFailureForTest(&state, spawn_address);
    try std.testing.expect(state.pending_document_generation == null);

    const capability_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.needs_document_revalidation = true;
    state.markDocumentCapabilityUnavailable();
    try expectIncomingRequestFailureForTest(&state, capability_address);
    try std.testing.expect(!state.needs_document_revalidation);
}

test "repository transition B2b2b1 manual reload rebinds one destination through manifest" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state = try selectionStateForTest("main.zig\x00", "old one\nold two\nold three\n");
    defer state.deinit(allocator);
    state.root_identity = root.capability.identity;
    state.freshness = .fresh;

    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        state.repo_epoch,
        state.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = 2 } },
    );
    const owned_address = @intFromPtr(incoming.location.path.ptr);
    state.acceptIncoming(allocator, &incoming);
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.document_generation = 7;
    state.pending_document_generation = 7;
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 7));

    state.requestReload(true);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));
    try std.testing.expect(state.pending_document_generation == null);
    try std.testing.expect(state.needs_revalidation);

    const stale_bytes = try allocator.dupe(u8, "stale source\n");
    var stale_document: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = state.root_identity.?,
        .generation = 7,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .source = try source_document.Document.initOwned(allocator, stale_bytes, .init(stale_bytes)) },
    };
    defer stale_document.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale_document));
    try std.testing.expect(state.incoming == .awaiting_manifest);

    var manifest_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer manifest_request.deinit(allocator);
    var manifest_finished: ManifestFinished = .{
        .identity = manifest_request.identity,
        .root_identity = manifest_request.root.identity,
        .generation = manifest_request.generation,
        .result = .{ .unchanged = state.bundle.?.document.fingerprint },
    };
    defer manifest_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &manifest_finished));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expect(state.needs_document_revalidation);

    var document_request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer document_request.deinit(allocator);
    try std.testing.expect(document_request.generation > 7);
    try std.testing.expectEqual(
        @as(?u64, document_request.generation),
        state.incoming.documentIntent().?.document_generation,
    );
    const new_bytes = try allocator.dupe(u8, "new one\nnew two\nnew three\n");
    var document_finished: DocumentFinished = .{
        .identity = document_request.identity,
        .root_identity = document_request.root.identity,
        .generation = document_request.generation,
        .manifest_revision = document_request.manifest_revision,
        .path = try allocator.dupe(u8, document_request.path),
        .value = .{ .source = try source_document.Document.initOwned(allocator, new_bytes, .init(new_bytes)) },
    };
    defer document_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &document_finished));
    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
    try std.testing.expectEqualStrings("new one\nnew two\nnew three\n", state.currentSource().?.bytes);
}

test "repository transition B2b2b1 reactivation rewinds or terminalizes document owner" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 3,
        .root_identity = root.capability.identity,
        .manifest_revision = 11,
        .document_generation = 12,
        .pending_document_generation = 12,
    };
    defer state.deinit(allocator);
    const retained_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "retained.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "retained.zig", 12));

    state.deactivate();
    state.activate(state.repo_epoch, root.capability.identity);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(retained_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));
    try std.testing.expect(state.pending_document_generation == null);
    try std.testing.expect(state.needs_revalidation);

    var stale_document: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = 2 },
        .root_identity = root.capability.identity,
        .generation = 12,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "retained.zig"),
        .value = .{ .inert = .binary },
    };
    defer stale_document.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale_document));
    try std.testing.expect(state.incoming == .awaiting_manifest);

    var manifest_request = try state.prepareRequest(allocator, root.path, &root.capability);
    defer manifest_request.deinit(allocator);
    var manifest_finished: ManifestFinished = .{
        .identity = manifest_request.identity,
        .root_identity = manifest_request.root.identity,
        .generation = manifest_request.generation,
        .result = .{ .loaded = try bundleForTest("retained.zig\x00") },
    };
    defer manifest_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &manifest_finished));
    try std.testing.expect(state.incoming == .awaiting_document);

    var document_request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer document_request.deinit(allocator);
    const bytes = try allocator.dupe(u8, "first\nsecond\nthird\n");
    var document_finished: DocumentFinished = .{
        .identity = document_request.identity,
        .root_identity = document_request.root.identity,
        .generation = document_request.generation,
        .manifest_revision = document_request.manifest_revision,
        .path = try allocator.dupe(u8, document_request.path),
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };
    defer document_finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &document_finished));
    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);

    const unavailable_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "no-root.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.activate(state.repo_epoch, null);
    try expectIncomingRequestFailureForTest(&state, unavailable_address);
    try std.testing.expect(!state.needs_revalidation);
    try std.testing.expectEqual(LoadState.no_repository, state.load_state);
}

test "repository transition B2b2b1 reactivation invalidates manifest predecessor" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 3,
        .root_identity = identity,
        .generation = 7,
        .pending_generation = 7,
    };
    defer state.deinit(allocator);
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "pending.zig");

    state.deactivate();
    state.activate(state.repo_epoch, identity);
    try std.testing.expect(state.pending_generation == null);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    state.markRequestPreparationFailed(error.OutOfMemory);
    try expectIncomingRequestFailureForTest(&state, owned_address);

    var stale_manifest: ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = 2 },
        .root_identity = identity,
        .generation = 7,
        .result = .{ .loaded = try bundleForTest("pending.zig\x00") },
    };
    defer stale_manifest.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(allocator, &stale_manifest));
    try expectIncomingRequestFailureForTest(&state, owned_address);
    try std.testing.expect(state.bundle == null);
}

test "repository transition B2b2b2a manifest mismatch keeps a current task successor" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .generation = 8,
        .pending_generation = 8,
    };
    defer state.deinit(allocator);
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "target.zig");

    var stale: ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 7,
        .result = .{ .failed_static = "stale manifest" },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(allocator, &stale));
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));

    var current: ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 8,
        .result = .{ .loaded = try bundleForTest("target.zig\x00") },
    };
    defer current.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(allocator, &current));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.documentIntent().?.location.path.ptr));

    // The manifest payload has no document-acceptance authority, but its
    // rejection still classifies the remaining owner's liveness. The accepted
    // manifest scheduled document revalidation, so that successor retains it.
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(allocator, &stale));
    try std.testing.expect(state.incoming == .awaiting_document);

    // Without that named document successor, the same reverse cross-stage
    // rejection closes the same path owner instead of retaining it forever.
    state.needs_document_revalidation = false;
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyFinished(allocator, &stale));
    try expectIncomingRequestFailureForTest(&state, owned_address);
}

test "repository transition B2b2b2a manifest mismatch keeps a scheduled successor" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .generation = 8,
        .needs_revalidation = true,
    };
    defer state.deinit(allocator);
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "scheduled.zig");

    var unmatched: ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 8,
        .result = .{ .failed_static = "unmatched manifest" },
    };
    defer unmatched.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(allocator, &unmatched));
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));

    // If the named scheduled attempt cannot be prepared, its existing
    // start-failure contract closes the same owner instead of adding a retry.
    state.markRequestPreparationFailed(error.OutOfMemory);
    try expectIncomingRequestFailureForTest(&state, owned_address);
}

test "repository transition B2b2b2a manifest mismatch keeps a dormant successor" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = false,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .generation = 8,
    };
    defer state.deinit(allocator);
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "dormant.zig");

    var unmatched: ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = 2 },
        .root_identity = identity,
        .generation = 7,
        .result = .{ .failed_static = "old activation" },
    };
    defer unmatched.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(allocator, &unmatched));
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));

    state.activate(state.repo_epoch, identity);
    try std.testing.expect(state.needs_revalidation);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    state.markRequestPreparationFailed(error.OutOfMemory);
    try expectIncomingRequestFailureForTest(&state, owned_address);
}

test "repository transition B2b2b2a manifest mismatch without successor closes owner" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .generation = 8,
    };
    defer state.deinit(allocator);
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "orphaned.zig");

    // The completion names the current generation but no pending task owns
    // that generation and no revalidation is scheduled.
    var unmatched: ManifestFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 8,
        .result = .{ .failed_static = "unowned completion" },
    };
    defer unmatched.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyFinished(allocator, &unmatched));
    try expectIncomingRequestFailureForTest(&state, owned_address);
    try std.testing.expect(state.bundle == null);
}

test "repository transition B2b2b2b document mismatch keeps a current task successor" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 9,
        .document_generation = 12,
        .pending_document_generation = 12,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 12));

    var stale: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 11,
        .manifest_revision = state.manifest_revision - 1,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .inert = .binary },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqual(@as(?u64, 12), state.pending_document_generation);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.documentIntent().?.location.path.ptr));

    const bytes = try allocator.dupe(u8, "one\ntwo\nthree\n");
    var current: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 12,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };
    defer current.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &current));
    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
}

test "repository transition B2b2b2b document mismatch keeps a scheduled successor" {
    const allocator = std.testing.allocator;
    var root = try TestRoot.init();
    defer root.deinit();
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = root.capability.identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 9,
        .document_generation = 12,
        .pending_document_generation = 12,
        .needs_document_revalidation = true,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 12));

    var stale: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = root.capability.identity,
        .generation = 12,
        .manifest_revision = state.manifest_revision - 1,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .inert = .binary },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expect(state.pending_document_generation == null);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.documentIntent().?.location.path.ptr));

    var request = try state.prepareDocumentRequest(allocator, &root.capability);
    defer request.deinit(allocator);
    try std.testing.expect(request.generation > 12);
    const bytes = try allocator.dupe(u8, "new one\nnew two\nnew three\n");
    var current: DocumentFinished = .{
        .identity = request.identity,
        .root_identity = request.root.identity,
        .generation = request.generation,
        .manifest_revision = request.manifest_revision,
        .path = try allocator.dupe(u8, request.path),
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };
    defer current.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &current));
    try std.testing.expect(state.incoming == .none);
    try std.testing.expectEqual(@as(usize, 1), state.viewer.source_cursor);
}

test "repository transition B2b2b2b document mismatch keeps a dormant successor" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = false,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .manifest_revision = 9,
        .document_generation = 12,
    };
    defer state.deinit(allocator);
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "dormant.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "dormant.zig", 11));

    var stale: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = 2 },
        .root_identity = identity,
        .generation = 11,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "dormant.zig"),
        .value = .{ .inert = .binary },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyDocumentFinished(allocator, &stale));
    try std.testing.expect(state.incoming == .awaiting_document);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.incoming.documentIntent().?.location.path.ptr));

    state.activate(state.repo_epoch, identity);
    try std.testing.expect(state.incoming == .awaiting_manifest);
    state.markRequestPreparationFailed(error.OutOfMemory);
    try expectIncomingRequestFailureForTest(&state, owned_address);
}

test "repository transition B2b2b2b document mismatch without successor closes owner" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 9,
        .document_generation = 12,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 11));

    var stale: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 11,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .inert = .binary },
    };
    defer stale.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyDocumentFinished(allocator, &stale));
    try expectIncomingRequestFailureForTest(&state, owned_address);
    try std.testing.expect(state.displayed_document == null);

    state.dismissIncoming(allocator);
    const wrong_path_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    state.document_generation = 13;
    state.pending_document_generation = 13;
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 13));
    var wrong_path: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 13,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "other.zig"),
        .value = .{ .inert = .binary },
    };
    defer wrong_path.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyDocumentFinished(allocator, &wrong_path));
    try expectIncomingRequestFailureForTest(&state, wrong_path_address);

    // Cross-stage rejection evaluates the manifest owner's own liveness. The
    // document root failure is not its terminal reason, but a scheduled
    // manifest revalidation is a valid reason to retain it.
    state.dismissIncoming(allocator);
    const manifest_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    state.needs_revalidation = true;
    state.document_generation = 14;
    state.pending_document_generation = 14;
    var wrong_root: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = .{ .device = identity.device, .inode = identity.inode +% 1 },
        .generation = 14,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .inert = .binary },
    };
    defer wrong_root.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyDocumentFinished(allocator, &wrong_root));
    try std.testing.expect(state.incoming == .awaiting_manifest);
    try std.testing.expectEqual(manifest_address, @intFromPtr(state.incoming.manifestIntent().?.path.ptr));

    // Once that named successor disappears, a later cross-stage rejection
    // closes the orphaned manifest owner rather than leaving it pending.
    state.needs_revalidation = false;
    state.document_generation = 15;
    state.pending_document_generation = 15;
    var no_successor_root: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = .{ .device = identity.device, .inode = identity.inode +% 1 },
        .generation = 15,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .inert = .binary },
    };
    defer no_successor_root.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.failed, state.applyDocumentFinished(allocator, &no_successor_root));
    try expectIncomingRequestFailureForTest(&state, manifest_address);
}

test "repository transition B2b2b2b accepted source closes inconsistent document owner" {
    const allocator = std.testing.allocator;
    const identity = root_capability.Identity{ .device = 5, .inode = 8 };
    var state: RepositoryPageState = .{
        .active = true,
        .activation_id = 3,
        .repo_epoch = 4,
        .root_identity = identity,
        .bundle = try bundleForTest("main.zig\x00"),
        .load_state = .loaded,
        .manifest_revision = 9,
        .document_generation = 12,
        .pending_document_generation = 12,
    };
    defer state.deinit(allocator);
    state.selected_path = state.bundle.?.tree.firstFilePath();
    const owned_address = try acceptIncomingFailureOwnerForTest(&state, allocator, "main.zig");
    try std.testing.expect(state.incoming.advanceToDocument(state.manifest_revision));
    try std.testing.expect(state.incoming.bindDocumentGeneration(state.manifest_revision, "main.zig", 11));

    const bytes = try allocator.dupe(u8, "accepted source\n");
    var finished: DocumentFinished = .{
        .identity = .{ .origin = .repository, .repo_epoch = state.repo_epoch, .activation_id = state.activation_id },
        .root_identity = identity,
        .generation = 12,
        .manifest_revision = state.manifest_revision,
        .path = try allocator.dupe(u8, "main.zig"),
        .value = .{ .source = try source_document.Document.initOwned(allocator, bytes, .init(bytes)) },
    };
    defer finished.deinit(allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyDocumentFinished(allocator, &finished));
    try expectIncomingRequestFailureForTest(&state, owned_address);
    try std.testing.expectEqualStrings("accepted source\n", state.currentSource().?.bytes);
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

test "repository root row renders disclosure and byte-safe basename" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expanded = try rootRowTextAlloc(arena.allocator(), "repo\xff\n", .expanded, 0, 40);
    try std.testing.expectEqualStrings("▾ repo\\xFF\\x0A", expanded);
    const collapsed = try rootRowTextAlloc(arena.allocator(), "repo", .collapsed, 0, 40);
    try std.testing.expectEqualStrings("▸ repo", collapsed);
    const partial_glyph_scroll = try rootRowTextAlloc(arena.allocator(), "repo", .expanded, 1, 40);
    try std.testing.expectEqualStrings("repo", partial_glyph_scroll);
}
