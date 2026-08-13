//! Compare adapter for the page-independent diff-surface navigation contract.

const std = @import("std");
const builtin = @import("builtin");
const compare_page = @import("../compare.zig");
const diff_surface = @import("../../diff_surface.zig");
const context = @import("../../../context.zig");
const content_fingerprint = @import("../../../content_fingerprint.zig");
const diff_file = @import("../../../diff/file.zig");
const diff_parser = @import("../../../diff/parser.zig");
const diff_render = @import("../../../diff/render.zig");
const diff_selection = @import("../../../diff/selection.zig");
const diff_source = @import("../../../diff/source.zig");
const diff_view_model = @import("../../../diff/view_model.zig");
const file_tree = @import("../../../file_tree.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const test_support = if (builtin.is_test) @import("../../test_support.zig") else struct {};

const source: diff_source.SourceMode = .{ .range = "compare" };

/// Read-only Compare adapter. Rendering and content inspection must construct
/// this value directly from a const page borrow; mutation authority belongs to
/// `Controller` below.
pub const View = struct {
    page: *const compare_page.ComparePageState,
    repo_root: ?[]const u8,
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,
    layout: diff_surface.Layout,

    pub fn view(self: View) diff_surface.navigation.View {
        return .{
            .surface = self.page.readSurface(source, self.layout),
            .repo_root = self.repo_root,
        };
    }

    pub fn bodyView(self: View, adapter: *BodyResolverAdapter) diff_surface.navigation.BodyView {
        return .{ .view = self.view(), .resolver = adapter.interface() };
    }

    pub fn resolver(self: View) BodyResolverAdapter {
        return .{ .context = self };
    }

    pub fn contentView(self: View, adapter: *BodyResolverAdapter) diff_surface.content.View {
        return .{ .navigation = self.bodyView(adapter) };
    }

    pub fn captureAnchor(self: View, allocator: std.mem.Allocator) !?diff_surface.ReloadAnchor {
        var adapter = self.resolver();
        const body = self.bodyView(&adapter);
        const loaded = body.view.activeLoadedDiffConst() orelse return null;
        const file = body.displayedDiffFile() orelse return null;
        const path_key = diff_file.canonicalPathKey(file) orelse return null;
        const sidebar_identity = body.view.selectedSidebarIdentity() orelse return null;
        const selected_target = self.page.viewer.selected_target orelse return null;

        const owned_path = try allocator.dupe(u8, path_key);
        errdefer allocator.free(owned_path);
        const owned_sidebar = try cloneSidebarIdentity(allocator, sidebar_identity);
        return .{
            .path_key = owned_path,
            .sidebar_identity = owned_sidebar,
            .selected_target_tag = std.meta.activeTag(selected_target),
            .visible_sidebar_row = loaded.visibleRowOfNode(self.page.viewer.selected_node) orelse 0,
            .diff_cursor = self.page.viewer.diff_cursor,
            .diff_cursor_offset = body.selectedDiffCursorOffset(),
            .diff_scroll = self.page.viewer.diff_scroll,
            .diff_horizontal_scroll = self.page.viewer.diff_horizontal_scroll,
            .sidebar_horizontal_scroll = self.page.viewer.sidebar_horizontal_scroll,
            .search_coordinate = if (self.page.search.match) |match| match.coordinate else null,
        };
    }
};

/// Mutable Compare adapter used only by update/input integration.
pub const Controller = struct {
    page: *compare_page.ComparePageState,
    repo_root: ?[]const u8,
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,
    layout: diff_surface.Layout,

    fn sharedController(self: Controller) diff_surface.navigation.Controller {
        return .{
            .surface = self.page.diffSurface(source, self.layout),
            .repo_root = self.repo_root,
            .repo_epoch = self.repo_epoch,
            .diagnostics = .{ .target = &self.page.status },
        };
    }

    pub fn view(self: Controller) View {
        return .{
            .page = self.page,
            .repo_root = self.repo_root,
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
            .layout = self.layout,
        };
    }

    /// Short-lived mutable adapter whose navigation and body resolver are
    /// constructed from the same Compare page owner. Callers cannot pair a
    /// controller from one page with a resolver borrowed from another page.
    pub const UpdateAdapter = struct {
        navigation: Controller,
        resolver: BodyResolverAdapter,

        pub fn bodyController(self: *UpdateAdapter) diff_surface.navigation.BodyController {
            return .{
                .controller = self.navigation.sharedController(),
                .resolver = self.resolver.interface(),
            };
        }

        pub fn shared(self: *UpdateAdapter) diff_surface.update.Controller {
            return .{ .navigation = self.bodyController() };
        }
    };

    pub fn updateAdapter(self: Controller) UpdateAdapter {
        return .{
            .navigation = self,
            .resolver = self.view().resolver(),
        };
    }
};

pub const BodyResolverAdapter = struct {
    context: View,

    pub fn interface(self: *BodyResolverAdapter) diff_surface.BodyResolver {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn from(ctx: *anyopaque) *BodyResolverAdapter {
        return @ptrCast(@alignCast(ctx));
    }

    const vtable: diff_surface.BodyResolver.VTable = .{
        .resolvedTarget = resolvedTarget,
        .hunkStagePresentation = hunkStagePresentation,
        .contentToken = contentToken,
        .renderProjectedBody = renderProjectedBody,
        .parsedSelectionTarget = parsedSelectionTarget,
        .displayedDiffFile = displayedDiffFile,
        .displayedSearchTarget = displayedSearchTarget,
        .displayedDiffLineIndex = displayedDiffLineIndex,
        .displayedDiffLineCount = displayedDiffLineCount,
        .generatedBody = generatedBody,
        .displayedDiffHeaderTarget = displayedDiffHeaderTarget,
    };

    fn current(self: *BodyResolverAdapter) ?struct { loaded: *const @import("../../../loaded_diff.zig").LoadedDiff, file_index: usize } {
        const loaded = self.context.view().activeLoadedDiffConst() orelse return null;
        const file_index = self.context.view().selectedFileIndex(loaded) orelse return null;
        if (file_index >= loaded.document.files.len) return null;
        return .{ .loaded = loaded, .file_index = file_index };
    }

    fn resolvedTarget(ctx: *anyopaque) diff_surface.ResolvedTarget {
        const self = from(ctx);
        const selected = self.current() orelse return emptyResolvedTarget();
        const selectable = selected.loaded.fileTextSelectable(selected.file_index);
        const mode = self.context.view().effectiveDisplayMode();
        return .{
            .kind = if (selectable) .primary else .inert,
            .line_count = selected.loaded.renderedLineIndex(selected.file_index, mode).lineCount(),
            .hunk_interaction = if (selectable) .available else .inert_invalid_utf8,
            .status_rows = 0,
            .search_unavailable = if (selectable) null else .invalid_utf8,
            .search_unfold_policy = if (selectable) .unfold_displayed else .suppressed,
            .folded_hunks_source = .underlying_load,
        };
    }

    fn hunkStagePresentation(_: *anyopaque, _: std.mem.Allocator, _: usize) anyerror!diff_render.HunkStagePresentation {
        return .all_staged;
    }

    fn contentToken(ctx: *anyopaque) ?diff_surface.ContentToken {
        const self = from(ctx);
        const selected = self.current() orelse return null;
        return .{
            .repo_epoch = self.context.repo_epoch,
            .root_identity = self.context.root_identity,
            .source = diff_surface.selection.SourceBasis.init(source),
            .source_session_revision = self.context.page.source_session_revision,
            .display = .{ .loaded = content_fingerprint.Fingerprint.init(selected.loaded.text) },
        };
    }

    fn renderProjectedBody(ctx: *anyopaque, args: diff_surface.RenderProjectedBodyArgs) anyerror!void {
        const selected = from(ctx).current() orelse return;
        const file = selected.loaded.document.files[selected.file_index];
        return diff_surface.view.renderStatusBody(
            diff_file.displayPath(file),
            diff_surface.invalid_utf8_body_message,
            file_tree.fileStats(file),
            args,
        );
    }

    fn parsedSelectionTarget(ctx: *anyopaque, expected: ?diff_selection.Identity) ?diff_surface.ParsedSelectionTarget {
        const self = from(ctx);
        const selected = self.current() orelse return null;
        if (!selected.loaded.fileTextSelectable(selected.file_index)) return null;
        const file = selected.loaded.document.files[selected.file_index];
        const path_key = diff_file.canonicalPathKey(file) orelse return null;
        const identity: diff_selection.Identity = .{ .loaded_file = .{ .file_index = selected.file_index, .path_key = path_key } };
        if (expected) |value| if (!value.eql(identity)) return null;
        const mode = self.context.view().effectiveDisplayMode();
        return .{
            .file = file,
            .line_index = selected.loaded.cachedRenderedLineIndex(selected.file_index, mode) orelse selected.loaded.renderedLineIndex(selected.file_index, mode),
            .folded_hunks = selected.loaded.foldedHunksForFile(selected.file_index),
            .identity = identity,
        };
    }

    fn displayedDiffFile(ctx: *anyopaque) ?diff_parser.FileDiff {
        const selected = from(ctx).current() orelse return null;
        return selected.loaded.document.files[selected.file_index];
    }

    fn displayedSearchTarget(ctx: *anyopaque, mode: diff_render.DisplayMode) ?diff_surface.SearchTarget {
        const self = from(ctx);
        const selected = self.current() orelse return null;
        if (!selected.loaded.fileTextSelectable(selected.file_index)) return null;
        return .{
            .file = selected.loaded.document.files[selected.file_index],
            .line_index = selected.loaded.renderedLineIndex(selected.file_index, mode),
            .folded_hunks = selected.loaded.foldedHunksForFile(selected.file_index),
        };
    }

    fn displayedDiffLineIndex(ctx: *anyopaque, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        const selected = from(ctx).current() orelse return null;
        return selected.loaded.cachedRenderedLineIndex(selected.file_index, mode);
    }

    fn displayedDiffLineCount(ctx: *anyopaque) usize {
        const self = from(ctx);
        const selected = self.current() orelse return 0;
        return selected.loaded.renderedLineIndex(selected.file_index, self.context.view().effectiveDisplayMode()).lineCount();
    }

    fn generatedBody(_: *anyopaque) ?diff_surface.GeneratedBody {
        return null;
    }

    fn displayedDiffHeaderTarget(ctx: *anyopaque, expected: ?diff_selection.HeaderIdentity) ?diff_surface.DiffHeaderTarget {
        const file = displayedDiffFile(ctx) orelse return null;
        const path_key = diff_file.canonicalPathKey(file) orelse return null;
        const identity: diff_selection.HeaderIdentity = .{ .kind = .loaded_file, .path_key = path_key };
        if (expected) |value| if (!value.eql(identity)) return null;
        return .{ .identity = identity, .display_path = diff_file.displayPath(file) };
    }
};

fn emptyResolvedTarget() diff_surface.ResolvedTarget {
    return .{
        .kind = .none,
        .line_count = 0,
        .hunk_interaction = .unavailable,
        .status_rows = 0,
        .search_unavailable = null,
        .search_unfold_policy = .suppressed,
        .folded_hunks_source = .underlying_load,
    };
}

fn cloneSidebarIdentity(allocator: std.mem.Allocator, identity: context.SidebarIdentity) !context.SidebarIdentity {
    return switch (identity) {
        .repo_root => .repo_root,
        .directory => |path| .{ .directory = try allocator.dupe(u8, path) },
        .file => |path| .{ .file = try allocator.dupe(u8, path) },
    };
}

test "Compare navigation separates read-only View from mutable Controller authority" {
    const view_page = @typeInfo(@FieldType(View, "page")).pointer;
    const controller_page = @typeInfo(@FieldType(Controller, "page")).pointer;
    try std.testing.expect(view_page.is_const);
    try std.testing.expect(!controller_page.is_const);
    try std.testing.expect(@FieldType(diff_surface.navigation.View, "surface") == diff_surface.ReadSurface);
    try std.testing.expect(@FieldType(diff_surface.navigation.Controller, "surface") == diff_surface.DiffSurface);
    try std.testing.expect(!@hasDecl(Controller, "bodyController"));
    try std.testing.expect(!@hasDecl(Controller, "resolver"));
    try std.testing.expect(@hasDecl(Controller, "updateAdapter"));
}

test "Compare selection release still emits immediate clipboard bytes" {
    const allocator = std.testing.allocator;
    var page: compare_page.ComparePageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
    };
    defer page.deinit(allocator);
    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 3 },
        .moved = true,
    } };
    const controller: Controller = .{
        .page = &page,
        .repo_root = null,
        .repo_epoch = 0,
        .root_identity = null,
        .layout = .{ .width = 80, .height = 20 },
    };
    var adapter = controller.updateAdapter();
    var update = try adapter.shared().apply(allocator, .{ .mouse_diff_release = null });
    defer update.deinit(allocator);
    var effect = update.takeEffect() orelse return error.ExpectedSelectionEffect;
    defer effect.deinit(allocator);
    switch (effect) {
        .copy_diff_selection => |text| try std.testing.expectEqualStrings("one\ntwo\nnew\n", text),
        .copy_diff_header_path => return error.ExpectedSelectionEffect,
    }
    try std.testing.expect(page.selection_owner == .none);

    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "stale" } },
        .side = .new,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    } };
    var rejected = try adapter.shared().apply(allocator, .{ .mouse_diff_release = null });
    defer rejected.deinit(allocator);
    try std.testing.expect(rejected.effect == null);
    try std.testing.expect(page.completed_selection == null);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expectEqualStrings("", page.status.text());
}
