//! Review adapter for the page-independent diff-surface navigation contract.

const std = @import("std");
const builtin = @import("builtin");
const review_page = @import("../review.zig");
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

const source: diff_source.SourceMode = review_page.selection_source;

/// Read-only Review adapter. Rendering and content inspection must construct
/// this value directly from a const page borrow; mutation authority belongs to
/// `Controller` below.
pub const View = struct {
    page: *const review_page.ReviewPageState,
    repo_root: ?[]const u8,
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,
    layout: diff_surface.Layout,
    mode_toggle_hint_width: u16 = 0,

    pub fn view(self: View) diff_surface.navigation.View {
        return .{
            .surface = self.page.readSurface(source, self.layout),
            .repo_root = self.repo_root,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
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
            .selection_viewport = body.captureSelectionViewportAnchor(),
            .diff_horizontal_scroll = self.page.viewer.diff_horizontal_scroll,
            .sidebar_horizontal_scroll = self.page.viewer.sidebar_horizontal_scroll,
            .search_coordinate = if (self.page.search.match) |match| match.coordinate else null,
        };
    }
};

/// Mutable Review adapter used only by update/input integration.
pub const Controller = struct {
    page: *review_page.ReviewPageState,
    repo_root: ?[]const u8,
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,
    layout: diff_surface.Layout,
    mode_toggle_hint_width: u16 = 0,

    fn sharedController(self: Controller) diff_surface.navigation.Controller {
        return .{
            .surface = self.page.diffSurface(source, self.layout),
            .repo_root = self.repo_root,
            .repo_epoch = self.repo_epoch,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
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
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
        };
    }

    /// Short-lived mutable adapter whose navigation and body resolver are
    /// constructed from the same Review page owner. Callers cannot pair a
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
            return .{
                .navigation = self.bodyController(),
                .retained_selection_install = .{ .ctx = self, .callback = installRetainedSelection },
            };
        }

        fn installRetainedSelection(ctx: *anyopaque) bool {
            const self: *UpdateAdapter = @ptrCast(@alignCast(ctx));
            return self.navigation.page.installPinnedSelectionBasis();
        }

        pub fn applyRetentionTransition(
            self: *UpdateAdapter,
            _: std.mem.Allocator,
            transition: diff_surface.update.RetentionTransition,
        ) void {
            switch (transition) {
                .none => {},
                .installed => {
                    var body = self.bodyController();
                    body.controller.revealCompletedSelectionAction(body.resolver);
                },
                .cleared => self.navigation.page.pinned_selection_basis = null,
            }
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

test "Review navigation separates read-only View from mutable Controller authority" {
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

test "Review selection release installs pinned retained actions" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .basis = .{
            .base = .{
                .full_ref = try allocator.dupe(u8, "refs/heads/main"),
                .display_name = try allocator.dupe(u8, "main"),
                .kind = .local,
                .oid = .{},
            },
            .head_display = try allocator.dupe(u8, "topic"),
            .merge_base_oid = .{},
            .head_oid = .{},
            .ahead_count = 1,
        },
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
    try std.testing.expect(update.effect == null);
    try std.testing.expectEqual(diff_surface.update.RetentionTransition.installed, update.retention_transition);
    adapter.applyRetentionTransition(allocator, update.retention_transition);
    try std.testing.expect(page.completed_selection != null);
    try std.testing.expect(page.pinned_selection_basis != null);
    try std.testing.expect(page.retainedSelectionAdmitted());
    try std.testing.expect(page.selection_owner == .none);

    var copied = try adapter.shared().apply(allocator, .{ .selection_action = .copy });
    defer copied.deinit(allocator);
    var effect = copied.takeEffect() orelse return error.ExpectedSelectionEffect;
    defer effect.deinit(allocator);
    switch (effect) {
        .copy_diff_selection => |text| try std.testing.expectEqualStrings("one\ntwo\nnew\n", text),
        .copy_diff_header_path => return error.ExpectedSelectionEffect,
    }
    var cleared = try adapter.shared().apply(allocator, .{ .selection_action = .clear });
    defer cleared.deinit(allocator);
    adapter.applyRetentionTransition(allocator, cleared.retention_transition);
    try std.testing.expectEqual(diff_surface.update.RetentionTransition.cleared, cleared.retention_transition);
    try std.testing.expect(page.completed_selection == null);
    try std.testing.expect(page.pinned_selection_basis == null);

    const release_cases = [_]struct {
        mode: diff_render.DisplayMode,
        side: diff_selection.Side,
        expected: []const u8,
    }{
        .{ .mode = .unified, .side = .old, .expected = "one\ntwo\nold\n" },
        .{ .mode = .side_by_side, .side = .old, .expected = "one\ntwo\nold\n" },
        .{ .mode = .side_by_side, .side = .new, .expected = "one\ntwo\nnew\n" },
    };
    for (release_cases) |case| {
        page.viewer.display_mode = case.mode;
        page.selection_owner = .{ .diff = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .side = case.side,
            .anchor = .{ .hunk_index = 0, .line_index = 0 },
            .focus = .{ .hunk_index = 0, .line_index = 3 },
            .moved = true,
        } };
        var released = try adapter.shared().apply(allocator, .{ .mouse_diff_release = null });
        defer released.deinit(allocator);
        try std.testing.expect(released.effect == null);
        adapter.applyRetentionTransition(allocator, released.retention_transition);
        try std.testing.expectEqual(case.side, page.completed_selection.?.value.parsed_diff.side);
        var copied_case = try adapter.shared().apply(allocator, .{ .selection_action = .copy });
        defer copied_case.deinit(allocator);
        var copied_effect = copied_case.takeEffect() orelse return error.ExpectedSelectionEffect;
        defer copied_effect.deinit(allocator);
        switch (copied_effect) {
            .copy_diff_selection => |text| try std.testing.expectEqualStrings(case.expected, text),
            .copy_diff_header_path => return error.ExpectedSelectionEffect,
        }
        var cleared_case = try adapter.shared().apply(allocator, .{ .selection_action = .clear });
        defer cleared_case.deinit(allocator);
        adapter.applyRetentionTransition(allocator, cleared_case.retention_transition);
    }

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
    try std.testing.expectEqualStrings("Could not retain selected text", page.status.text());
}

test "Review keyboard line selection completes with exact pin and retries allocation failure" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .basis = .{
            .base = .{
                .full_ref = try allocator.dupe(u8, "refs/heads/main"),
                .display_name = try allocator.dupe(u8, "main"),
                .kind = .local,
                .oid = .{},
            },
            .head_display = try allocator.dupe(u8, "topic"),
            .merge_base_oid = .{},
            .head_oid = .{},
            .ahead_count = 1,
        },
        .viewer = .{
            .focus = .diff,
            .sidebar_hidden = true,
            .display_mode = .side_by_side,
        },
    };
    defer page.deinit(allocator);
    const controller: Controller = .{
        .page = &page,
        .repo_root = null,
        .repo_epoch = 0,
        .root_identity = null,
        .layout = .{ .width = 120, .height = 20 },
    };
    var adapter = controller.updateAdapter();

    var choose = try adapter.shared().apply(null, .{ .keyboard_select_side = .new });
    choose.deinit(null);
    var begin = try adapter.shared().apply(null, .begin_keyboard_line_selection);
    begin.deinit(null);
    for (0..2) |_| {
        var moved = try adapter.shared().apply(null, .{ .keyboard_line_selection_move = .down });
        moved.deinit(null);
    }
    try std.testing.expect(page.selection_owner.activeKeyboardLineSelection());
    try std.testing.expectEqual(@as(usize, 3), page.selection_owner.activeDiff().?.selected_line_count);

    var copied = try adapter.shared().apply(allocator, .{ .selection_action = .copy });
    defer copied.deinit(allocator);
    try std.testing.expectEqual(diff_surface.update.RetentionTransition.installed, copied.retention_transition);
    try std.testing.expect(page.pinned_selection_basis.?.eql(review_page.PinnedSelectionBasis.init(page.basis.?)));
    var effect = copied.takeEffect() orelse return error.ExpectedSelectionEffect;
    defer effect.deinit(allocator);
    switch (effect) {
        .copy_diff_selection => |text| try std.testing.expectEqualStrings("one\ntwo\nnew\n", text),
        .copy_diff_header_path => return error.ExpectedSelectionEffect,
    }
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.completed_selection != null);
    const prior_pin = page.pinned_selection_basis.?;
    const prior_text = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(prior_text);

    var second_begin = try adapter.shared().apply(null, .begin_keyboard_line_selection);
    second_begin.deinit(null);
    var second_move = try adapter.shared().apply(null, .{ .keyboard_line_selection_move = .down });
    second_move.deinit(null);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var rejected = try adapter.shared().apply(failing.allocator(), .{ .selection_action = .copy });
    rejected.deinit(failing.allocator());
    try std.testing.expect(page.selection_owner.activeKeyboardLineSelection());
    try std.testing.expect(page.pinned_selection_basis.?.eql(prior_pin));
    const retained_text = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(retained_text);
    try std.testing.expectEqualStrings(prior_text, retained_text);
    try std.testing.expectEqualStrings("Could not retain selected text; press y to retry", page.status.text());

    var cleared = try adapter.shared().apply(allocator, .{ .selection_action = .clear });
    defer cleared.deinit(allocator);
    adapter.applyRetentionTransition(allocator, cleared.retention_transition);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.completed_selection == null);
    try std.testing.expect(page.pinned_selection_basis == null);
}

test "Review retained candidate and pin replace transactionally and survive rejected installs" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .basis = .{
            .base = .{
                .full_ref = try allocator.dupe(u8, "refs/heads/main"),
                .display_name = try allocator.dupe(u8, "main"),
                .kind = .local,
                .oid = .{},
            },
            .head_display = try allocator.dupe(u8, "topic"),
            .merge_base_oid = .{},
            .head_oid = .{},
            .ahead_count = 1,
        },
    };
    defer page.deinit(allocator);
    const controller: Controller = .{
        .page = &page,
        .repo_root = null,
        .repo_epoch = 0,
        .root_identity = null,
        .layout = .{ .width = 80, .height = 20 },
    };
    var adapter = controller.updateAdapter();

    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    } };
    var initial = try adapter.shared().apply(allocator, .{ .mouse_diff_release = null });
    defer initial.deinit(allocator);
    adapter.applyRetentionTransition(allocator, initial.retention_transition);
    const initial_token = page.completed_selection.?.token;
    const initial_pin = page.pinned_selection_basis.?;
    const initial_fragment_ptr = page.completed_selection.?.value.parsed_diff.fragments.items[0].text.ptr;
    const initial_text = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(initial_text);
    try std.testing.expectEqualStrings("one\ntwo\n", initial_text);

    // A newly accepted basis must replace both halves of the retained owner.
    // The candidate is built before the prior allocation is retired, so the
    // new fragment cannot alias the old allocation.
    page.basis.?.head_oid.len = 1;
    page.basis.?.head_oid.bytes[0] = 'c';
    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 3 },
        .focus = .{ .hunk_index = 0, .line_index = 4 },
        .moved = true,
    } };
    var replacement = try adapter.shared().apply(allocator, .{ .mouse_diff_release = null });
    defer replacement.deinit(allocator);
    try std.testing.expectEqual(diff_surface.update.RetentionTransition.installed, replacement.retention_transition);
    adapter.applyRetentionTransition(allocator, replacement.retention_transition);
    const replacement_token = page.completed_selection.?.token;
    const replacement_pin = page.pinned_selection_basis.?;
    const replacement_fragment_ptr = page.completed_selection.?.value.parsed_diff.fragments.items[0].text.ptr;
    const replacement_text = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(replacement_text);
    try std.testing.expectEqualStrings("new\nfour\n", replacement_text);
    try std.testing.expect(replacement_fragment_ptr != initial_fragment_ptr);
    try std.testing.expect(replacement_token.eql(initial_token));
    try std.testing.expect(!replacement_pin.eql(initial_pin));
    try std.testing.expect(replacement_pin.eql(review_page.PinnedSelectionBasis.init(page.basis.?)));

    // Candidate construction failure must leave the prior candidate and pin
    // byte-for-byte authoritative while ending only the live drag.
    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .old,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 3 },
        .moved = true,
    } };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var allocation_failure = try adapter.shared().apply(failing.allocator(), .{ .mouse_diff_release = null });
    defer allocation_failure.deinit(failing.allocator());
    try std.testing.expect(allocation_failure.effect == null);
    try std.testing.expectEqual(diff_surface.update.RetentionTransition.none, allocation_failure.retention_transition);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.completed_selection.?.token.eql(replacement_token));
    try std.testing.expect(page.pinned_selection_basis.?.eql(replacement_pin));
    const after_allocation_failure = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(after_allocation_failure);
    try std.testing.expectEqualStrings(replacement_text, after_allocation_failure);
    try std.testing.expectEqualStrings("Could not retain selected text", page.status.text());

    // The shared pre-admission gate also rejects an impossible selectable
    // state without publishing a candidate ahead of its missing basis pin.
    const detached_basis = page.basis.?;
    page.basis = null;
    defer if (page.basis == null) {
        page.basis = detached_basis;
    };
    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 3 },
        .moved = true,
    } };
    var pin_rejection = try adapter.shared().apply(allocator, .{ .mouse_diff_release = null });
    defer pin_rejection.deinit(allocator);
    try std.testing.expect(pin_rejection.effect == null);
    try std.testing.expectEqual(diff_surface.update.RetentionTransition.none, pin_rejection.retention_transition);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.completed_selection.?.token.eql(replacement_token));
    try std.testing.expect(page.pinned_selection_basis.?.eql(replacement_pin));
    const after_pin_rejection = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(after_pin_rejection);
    try std.testing.expectEqualStrings(replacement_text, after_pin_rejection);
    try std.testing.expectEqualStrings("Could not retain selected text", page.status.text());
    page.basis = detached_basis;
}
