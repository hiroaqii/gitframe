const std = @import("std");
const chasen = @import("chasen");
const draw = @import("draw");
const theme = @import("theme");
const app_state = @import("../state.zig");
const auto_reload = @import("../auto_reload.zig");
const page = @import("../page.zig");
const git_backend = @import("../../git/backend.zig");
const manifest = @import("../../repository/manifest.zig");
const repository_tree = @import("../../repository/tree.zig");

pub const LoadState = enum { idle, no_repository, loading, loaded, empty, failed };

pub const Bundle = struct {
    document: manifest.Document,
    tree: repository_tree.Tree,

    pub fn deinit(self: *Bundle, allocator: std.mem.Allocator) void {
        self.tree.deinit(allocator);
        self.document.deinit(allocator);
        self.* = undefined;
    }
};

pub const TaskResult = union(enum) {
    unchanged: auto_reload.SourceFingerprint,
    loaded: Bundle,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: *TaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .unchanged, .failed_static => {},
            .loaded => |*bundle| bundle.deinit(allocator),
            .failed => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

pub const ManifestFinished = struct {
    identity: page.RequestIdentity,
    generation: u64,
    repo_root: []u8,
    result: TaskResult,

    pub fn deinit(self: *ManifestFinished, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const Msg = union(enum) {
    manifest_finished: ManifestFinished,
    move_up,
    move_down,
    toggle_directory,
    page_up,
    page_down,
    scroll_left,
    scroll_right,
    mouse_row: usize,
    mouse_toggle_row: usize,
    wheel_up,
    wheel_down,

    pub fn deinitUndelivered(self: *Msg, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .manifest_finished => |*finished| finished.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

pub fn ManifestTask(comptime AppMsg: type) type {
    return struct {
        identity: page.RequestIdentity,
        generation: u64,
        repo_root: []u8,
        expected_fingerprint: ?auto_reload.SourceFingerprint,

        pub fn run(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            const finished = ManifestFinished{
                .identity = task.identity,
                .generation = task.generation,
                .repo_root = task.repo_root,
                .result = runManifestLoad(task.repo_root, task.expected_fingerprint, allocator, io),
            };
            task.repo_root = &.{};
            return .{ .repository = .{ .manifest_finished = finished } };
        }

        pub fn failed(ctx_ptr: *anyopaque, failure: chasen.TaskFailure, allocator: std.mem.Allocator) AppMsg {
            const task: *@This() = @ptrCast(@alignCast(ctx_ptr));
            defer allocator.destroy(task);
            const finished = ManifestFinished{
                .identity = task.identity,
                .generation = task.generation,
                .repo_root = task.repo_root,
                .result = .{ .failed_static = switch (failure) {
                    .start_failed => |message| message,
                    .runtime_abandoned => "runtime shutting down",
                } },
            };
            task.repo_root = &.{};
            return .{ .repository = .{ .manifest_finished = finished } };
        }
    };
}

pub fn runManifestLoad(
    repo_root: []const u8,
    expected_fingerprint: ?auto_reload.SourceFingerprint,
    allocator: std.mem.Allocator,
    io: std.Io,
) TaskResult {
    var backend: git_backend.LocalCommandBackend = .{};
    const raw = backend.backend().loadRepositoryManifest(allocator, io, .{ .repo_root = repo_root }) catch |err| {
        return failureAlloc(allocator, "Repository manifest load failed: {s}", .{@errorName(err)});
    };
    switch (raw) {
        .ok => |bytes| {
            const fingerprint = auto_reload.SourceFingerprint.init(bytes);
            if (expected_fingerprint) |expected| {
                if (expected.eql(fingerprint)) {
                    allocator.free(bytes);
                    return .{ .unchanged = fingerprint };
                }
            }
            var document = manifest.parseOwned(allocator, bytes) catch |err| {
                return failureAlloc(allocator, "Repository manifest parse failed: {s}", .{@errorName(err)});
            };
            const tree = repository_tree.Tree.build(allocator, &document) catch |err| {
                document.deinit(allocator);
                return failureAlloc(allocator, "Repository tree build failed: {s}", .{@errorName(err)});
            };
            return .{ .loaded = .{ .document = document, .tree = tree } };
        },
        .failed => |message| return .{ .failed = message },
        .failed_static => |message| return .{ .failed_static = message },
    }
}

fn failureAlloc(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) TaskResult {
    return .{ .failed = std.fmt.allocPrint(allocator, format, args) catch
        return .{ .failed_static = "Repository manifest load failed: OutOfMemory" } };
}

pub const Request = struct {
    identity: page.RequestIdentity,
    generation: u64,
    repo_root: []u8,
    expected_fingerprint: ?auto_reload.SourceFingerprint,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
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
    generation: u64 = 0,
    pending_generation: ?u64 = null,
    needs_revalidation: bool = false,
    freshness: enum { unavailable, validating, fresh, failed } = .unavailable,
    load_state: LoadState = .idle,
    bundle: ?Bundle = null,
    selected_path: ?[]const u8 = null,
    cursor_visible: usize = 0,
    vertical_scroll: usize = 0,
    horizontal_scroll: usize = 0,
    status: app_state.StatusMessage = .{},

    pub fn deinit(self: *RepositoryPageState, allocator: std.mem.Allocator) void {
        if (self.bundle) |*bundle| bundle.deinit(allocator);
        self.* = .{};
    }

    pub fn activate(self: *RepositoryPageState, repo_epoch: u64, has_repository: bool) void {
        self.initialized = true;
        self.active = true;
        self.activation_id +%= 1;
        if (self.activation_id == 0) self.activation_id = 1;
        if (self.repo_epoch != repo_epoch) self.repo_epoch = repo_epoch;
        if (!has_repository) {
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

    pub fn repositoryChanged(self: *RepositoryPageState, allocator: ?std.mem.Allocator, repo_epoch: u64, has_repository: bool) void {
        if (self.bundle) |*bundle| {
            const owner = allocator orelse @panic("Repository bundle replacement requires an allocator");
            bundle.deinit(owner);
        }
        self.bundle = null;
        self.selected_path = null;
        self.cursor_visible = 0;
        self.vertical_scroll = 0;
        self.horizontal_scroll = 0;
        self.pending_generation = null;
        self.repo_epoch = repo_epoch;
        self.status.clear();
        self.load_state = if (has_repository) .idle else .no_repository;
        self.freshness = if (has_repository) .validating else .unavailable;
        self.needs_revalidation = self.active and has_repository;
    }

    pub fn prepareRequest(self: *RepositoryPageState, allocator: std.mem.Allocator, repo_root: []const u8) !Request {
        const owned_root = try allocator.dupe(u8, repo_root);
        errdefer allocator.free(owned_root);
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.pending_generation = self.generation;
        self.needs_revalidation = false;
        self.freshness = .validating;
        if (self.bundle == null) self.load_state = .loading;
        return .{
            .identity = .{ .origin = .repository, .repo_epoch = self.repo_epoch, .activation_id = self.activation_id },
            .generation = self.generation,
            .repo_root = owned_root,
            .expected_fingerprint = if (self.bundle) |*bundle| bundle.document.fingerprint else null,
        };
    }

    pub fn rejectSpawn(self: *RepositoryPageState, generation: u64) void {
        if (self.pending_generation == generation) self.pending_generation = null;
        self.freshness = .failed;
        if (self.bundle == null) self.load_state = .failed;
        self.status.set("Could not start repository manifest task", .{});
    }

    pub fn requestReload(self: *RepositoryPageState, has_repository: bool) void {
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

    pub fn markRequestPreparationFailed(self: *RepositoryPageState, err: anyerror) void {
        self.freshness = .failed;
        if (self.bundle == null) self.load_state = .failed;
        self.status.set("Could not prepare repository manifest: {s}", .{@errorName(err)});
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
        switch (finished.result) {
            .unchanged => {
                self.freshness = if (self.active) .fresh else .validating;
                self.status.clear();
                return .unchanged;
            },
            .loaded => |*incoming| {
                self.replaceBundle(allocator, incoming) catch |err| {
                    self.acceptFailure(@errorName(err));
                    return .failed;
                };
                finished.result = .{ .unchanged = self.bundle.?.document.fingerprint };
                self.freshness = if (self.active) .fresh else .validating;
                self.status.clear();
                return .changed;
            },
            .failed => |message| {
                self.acceptFailure(message);
                return .failed;
            },
            .failed_static => |message| {
                self.acceptFailure(message);
                return .failed;
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
        self.cursor_visible = if (selected) |path| self.bundle.?.tree.visibleIndexForPath(path) orelse 0 else 0;
        self.clampScroll(0);
    }

    fn acceptFailure(self: *RepositoryPageState, message: []const u8) void {
        self.freshness = .failed;
        if (self.bundle == null) self.load_state = .failed;
        self.status.set("{s}", .{message});
    }

    pub fn applyNavigation(self: *RepositoryPageState, msg: Msg, body_size: chasen.Size) void {
        const body_height = bodyLayout(body_size).treeRows(body_size.height);
        switch (msg) {
            .move_up, .wheel_up => self.moveCursor(-1, body_height),
            .move_down, .wheel_down => self.moveCursor(1, body_height),
            .page_up => self.moveCursor(-@as(isize, @intCast(@max(body_height -| 1, 1))), body_height),
            .page_down => self.moveCursor(@intCast(@max(body_height -| 1, 1)), body_height),
            .toggle_directory => self.toggleCursor(body_height),
            .scroll_left => self.horizontal_scroll -|= 4,
            .scroll_right => self.horizontal_scroll = @min(self.horizontal_scroll +| 4, manifest.max_path_bytes * 4),
            .mouse_row => |row| self.setCursor(row, body_height, false),
            .mouse_toggle_row => |row| self.setCursor(row, body_height, true),
            .manifest_finished => unreachable,
        }
    }

    fn moveCursor(self: *RepositoryPageState, delta: isize, body_height: u16) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        if (tree.visible_len == 0) return;
        if (delta < 0) self.cursor_visible -|= @intCast(-delta) else self.cursor_visible = @min(self.cursor_visible +| @as(usize, @intCast(delta)), tree.visible_len - 1);
        self.selectCursor();
        self.clampScroll(body_height);
    }

    fn setCursor(self: *RepositoryPageState, body_row: usize, body_height: u16, toggle: bool) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        const index = self.vertical_scroll + body_row;
        if (index >= tree.visible_len) return;
        self.cursor_visible = index;
        if (toggle and tree.nodes[tree.visible[index]].kind == .directory) self.toggleCursor(body_height) else self.selectCursor();
    }

    fn toggleCursor(self: *RepositoryPageState, body_height: u16) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        if (tree.toggleVisible(self.cursor_visible)) {
            if (tree.visible_len > 0) self.cursor_visible = @min(self.cursor_visible, tree.visible_len - 1);
            self.clampScroll(body_height);
        } else self.selectCursor();
    }

    fn selectCursor(self: *RepositoryPageState) void {
        const tree = if (self.bundle) |*bundle| &bundle.tree else return;
        if (self.cursor_visible >= tree.visible_len) return;
        const node = tree.nodes[tree.visible[self.cursor_visible]];
        if (node.kind == .file) self.selected_path = node.path;
    }

    pub fn clampScroll(self: *RepositoryPageState, body_height: u16) void {
        const visible_len = if (self.bundle) |*bundle| bundle.tree.visible_len else 0;
        if (visible_len == 0) {
            self.cursor_visible = 0;
            self.vertical_scroll = 0;
            return;
        }
        self.cursor_visible = @min(self.cursor_visible, visible_len - 1);
        const rows: usize = @max(@as(usize, body_height), 1);
        if (self.cursor_visible < self.vertical_scroll) self.vertical_scroll = self.cursor_visible;
        if (self.cursor_visible >= self.vertical_scroll + rows) self.vertical_scroll = self.cursor_visible - rows + 1;
        self.vertical_scroll = @min(self.vertical_scroll, visible_len -| rows);
    }

    pub fn clampForBodySize(self: *RepositoryPageState, body_size: chasen.Size) void {
        self.clampScroll(bodyLayout(body_size).treeRows(body_size.height));
    }

    pub fn mouseToMsg(self: *const RepositoryPageState, point: BodyPoint, button: MouseButton, size: chasen.Size) ?Msg {
        const layout = bodyLayout(size);
        if (point.col >= layout.tree_width) return null;
        return switch (button) {
            .wheel_up => .wheel_up,
            .wheel_down => .wheel_down,
            .left => {
                const body_row = layout.treeBodyRow(point) orelse return null;
                const tree = if (self.bundle) |*bundle| &bundle.tree else return null;
                const visible_index = self.vertical_scroll + body_row;
                if (visible_index >= tree.visible_len) return null;
                const node = tree.nodes[tree.visible[visible_index]];
                return if (node.kind == .directory)
                    .{ .mouse_toggle_row = body_row }
                else
                    .{ .mouse_row = body_row };
            },
        };
    }
};

pub fn keyToMsg(key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.up, .{}) or key.codepoint == 'k') return .move_up;
    if (key.matches(chasen.Key.down, .{}) or key.codepoint == 'j') return .move_down;
    if (key.matches(chasen.Key.page_up, .{})) return .page_up;
    if (key.matches(chasen.Key.page_down, .{})) return .page_down;
    if (key.matches(chasen.Key.enter, .{}) or key.codepoint == ' ') return .toggle_directory;
    if (key.matches(chasen.Key.left, .{}) or key.codepoint == 'h') return .scroll_left;
    if (key.matches(chasen.Key.right, .{}) or key.codepoint == 'l') return .scroll_right;
    return null;
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
        .idle, .no_repository, .loading, .failed => {
            const label: []const u8 = switch (state.load_state) {
                .idle => "Repository not loaded",
                .no_repository => "Repository required",
                .loading => "Loading repository files...",
                .failed => if (state.status.text().len > 0) state.status.text() else "Repository manifest failed",
                else => unreachable,
            };
            draw.copyClippedTextAt(surface, 1, size.height / 2, label, context.palette.style(if (state.load_state == .failed) .danger else .muted)) catch {};
            return;
        },
        .empty => {
            draw.copyClippedTextAt(surface, 1, size.height / 2, "Repository has no tracked or non-ignored files", context.palette.style(.muted)) catch {};
            return;
        },
        .loaded => {},
    }

    const layout = bodyLayout(size);
    const left_width = layout.tree_width;
    var left = surface.child(.{ .col = 0, .row = 0, .width = left_width, .height = size.height });
    draw.copyClippedTextAt(&left, 1, 0, "Repository files", context.palette.boldStyle(.accent)) catch {};
    if (left_width < size.width) {
        var separator_row: u16 = 0;
        while (separator_row < size.height) : (separator_row += 1) _ = surface.borrowTextAt(left_width, separator_row, "│", context.palette.style(.muted));
    }

    const tree = &state.bundle.?.tree;
    const rows = layout.treeRows(size.height);
    var body_row: usize = 0;
    while (body_row < rows and state.vertical_scroll + body_row < tree.visible_len) : (body_row += 1) {
        const visible_index = state.vertical_scroll + body_row;
        const node = tree.nodes[tree.visible[visible_index]];
        const visible_text = try treeRowTextAlloc(
            surface.frameAllocator(),
            node,
            state.horizontal_scroll,
            left_width -| 1,
        );
        const style = if (visible_index == state.cursor_visible) context.palette.boldStyle(.prompt) else if (node.kind == .directory) context.palette.boldStyle(.accent) else context.palette.style(.muted);
        draw.copyClippedTextAt(&left, 1, @intCast(body_row + 1), visible_text, style) catch {};
    }

    if (left_width + 1 >= size.width) return;
    var right = surface.child(.{ .col = left_width + 1, .row = 0, .width = size.width - left_width - 1, .height = size.height });
    if (state.selected_path) |path| {
        const path_window = try manifest.displayWindowAlloc(surface.frameAllocator(), path, 0, right.size().width -| 1);
        draw.copyClippedTextAt(&right, 1, 0, path_window.text(), context.palette.boldStyle(.accent)) catch {};
        if (size.height > 2) draw.copyClippedTextAt(&right, 1, 2, "No file content loaded", context.palette.style(.muted)) catch {};
    } else {
        draw.copyClippedTextAt(&right, 1, 0, "No file selected", context.palette.style(.muted)) catch {};
    }
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
    state.activate(3, true);
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
    state.cursor_visible = 1;
    state.applyNavigation(.toggle_directory, .{ .width = 60, .height = 11 });
    try std.testing.expectEqualStrings("a/one.zig", state.selected_path.?);
    state.cursor_visible = 0;
    state.applyNavigation(.toggle_directory, .{ .width = 60, .height = 11 });
    try std.testing.expectEqualStrings("a/one.zig", state.selected_path.?);
}

fn bundleForTest(bytes: []const u8) !Bundle {
    var document = try manifest.parseOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
    errdefer document.deinit(std.testing.allocator);
    return .{ .tree = try repository_tree.Tree.build(std.testing.allocator, &document), .document = document };
}

test "repository page accepts active and inactive matching manifest completions" {
    var state: RepositoryPageState = .{};
    defer state.deinit(std.testing.allocator);
    state.activate(7, true);
    var request = try state.prepareRequest(std.testing.allocator, "/repo");
    defer request.deinit(std.testing.allocator);
    var finished = ManifestFinished{
        .identity = request.identity,
        .generation = request.generation,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = try bundleForTest("src/main.zig\x00") },
    };
    defer finished.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(std.testing.allocator, &finished));
    try std.testing.expectEqualStrings("src/main.zig", state.selected_path.?);
    try std.testing.expect(state.freshness == .fresh);

    state.needs_revalidation = true;
    var unchanged_request = try state.prepareRequest(std.testing.allocator, "/repo");
    defer unchanged_request.deinit(std.testing.allocator);
    const retained_bundle = &state.bundle.?;
    var unchanged = ManifestFinished{
        .identity = unchanged_request.identity,
        .generation = unchanged_request.generation,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .unchanged = retained_bundle.document.fingerprint },
    };
    defer unchanged.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.unchanged, state.applyFinished(std.testing.allocator, &unchanged));
    try std.testing.expectEqual(retained_bundle, &state.bundle.?);

    state.needs_revalidation = true;
    var inactive_request = try state.prepareRequest(std.testing.allocator, "/repo");
    defer inactive_request.deinit(std.testing.allocator);
    state.deactivate();
    var inactive = ManifestFinished{
        .identity = inactive_request.identity,
        .generation = inactive_request.generation,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = try bundleForTest("README.md\x00src/main.zig\x00") },
    };
    defer inactive.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.changed, state.applyFinished(std.testing.allocator, &inactive));
    try std.testing.expect(state.bundle != null);
    try std.testing.expect(state.freshness == .validating);
    state.activate(7, true);
    try std.testing.expect(state.needs_revalidation);
}

test "repository page rejects stale completion and undelivered message frees payload" {
    var state: RepositoryPageState = .{};
    defer state.deinit(std.testing.allocator);
    state.activate(2, true);
    var request = try state.prepareRequest(std.testing.allocator, "/repo");
    defer request.deinit(std.testing.allocator);
    var stale = ManifestFinished{
        .identity = .{ .origin = .repository, .repo_epoch = 1, .activation_id = request.identity.activation_id },
        .generation = request.generation,
        .repo_root = try std.testing.allocator.dupe(u8, "/old"),
        .result = .{ .loaded = try bundleForTest("old.zig\x00") },
    };
    defer stale.deinit(std.testing.allocator);
    try std.testing.expectEqual(ApplyOutcome.discarded, state.applyFinished(std.testing.allocator, &stale));
    try std.testing.expect(state.bundle == null);

    var undelivered = Msg{ .manifest_finished = .{
        .identity = request.identity,
        .generation = request.generation,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = try bundleForTest("owned.zig\x00") },
    } };
    undelivered.deinitUndelivered(std.testing.allocator);
}

test "repository page renders tree and selected-path placeholder" {
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
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "No file content loaded") != null);
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
    try std.testing.expect(state.mouseToMsg(.{ .col = 1, .row = 0 }, .left, wide) == null);
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
    state.activate(1, false);
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
