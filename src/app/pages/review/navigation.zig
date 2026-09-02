//! Review adapter for the page-independent diff-surface navigation contract.

const std = @import("std");
const builtin = @import("builtin");
const review_page = @import("../review.zig");
const finding_card = @import("../../../ai_review/finding_card.zig");
const finding_projection = @import("../../../ai_review/finding_projection.zig");
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
const loaded_diff = @import("../../../loaded_diff.zig");
const committed_review = @import("../../../committed_review.zig");
const review_store = @import("../../../review_store.zig");
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
    presentation_rows: ?*const diff_render.PresentationRows = null,

    pub fn view(self: View) diff_surface.navigation.View {
        return .{
            .surface = self.page.readSurface(source, self.layout),
            .repo_root = self.repo_root,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
            .presentation_rows = self.presentation_rows,
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

    pub fn withPresentationRows(self: View, rows: ?*const diff_render.PresentationRows) View {
        var result = self;
        result.presentation_rows = rows;
        return result;
    }

    pub fn findingCardAtCursor(self: View) bool {
        if (self.page.viewer.focus != .diff or self.view().effectiveDisplayMode() != .unified) return false;
        const cursor = switch (self.page.viewer.diff_cursor) {
            .hunk_line => |line| line,
            else => return false,
        };
        const loaded = self.view().activeLoadedDiffConst() orelse return false;
        const file_index = self.view().selectedFileIndex(loaded) orelse return false;
        if (!loaded.fileTextSelectable(file_index)) return false;
        const pinned = self.page.pinnedAiConst() orelse return false;
        if (file_index >= pinned.selection.finding_projection.files.len) return false;
        const folded = loaded.foldedHunksForFile(file_index);
        if (cursor.hunk_index < folded.len and folded[cursor.hunk_index]) return false;
        const file_record = pinned.selection.finding_projection.files[file_index];
        for (file_record.mapped_entry_indices) |entry_index| {
            const model = finding_card.FindingCardModel.init(&pinned.selection.finding_projection, entry_index) orelse continue;
            if (model.span.file_ordinal != file_index) continue;
            if (model.span.hunk_ordinal != cursor.hunk_index or model.span.last_diff_line_ordinal != cursor.line_index) continue;
            if (self.page.contentForFindingCard(model) != null) return true;
        }
        return false;
    }

    pub fn buildFindingCardFrame(self: View, allocator: std.mem.Allocator) !?FindingCardFrame {
        return self.buildFindingCardFrameForState(allocator, self.page.finding_card);
    }

    pub fn prepareFindingCardFrame(
        self: View,
        allocator: std.mem.Allocator,
    ) (std.mem.Allocator.Error || error{InvalidFindingCardPreparation})!?FindingCardFramePreparation {
        const loaded = self.view().activeLoadedDiffConst() orelse return null;
        const pinned = self.page.pinnedAiConst() orelse return null;
        const entry_capacity = pinned.selection.finding_projection.entries.len;
        if (entry_capacity == 0) return null;
        if (entry_capacity > committed_review.limits.max_findings) return error.InvalidFindingCardPreparation;
        const block_capacity = std.math.mul(usize, entry_capacity, 2) catch
            return error.InvalidFindingCardPreparation;
        const inserted_bound = std.math.mul(
            usize,
            entry_capacity,
            finding_card.expanded_rows + finding_card.group_spacer_rows,
        ) catch return error.InvalidFindingCardPreparation;
        // Production load records this complete raw-input line count once.
        // It bounds every parsed file's unified body rows (including their
        // non-body file-header allowance) without a navigation-time scan.
        _ = std.math.add(usize, loaded.lines, inserted_bound) catch
            return error.InvalidFindingCardPreparation;
        return try FindingCardFramePreparation.init(
            allocator,
            &pinned.selection,
            loaded,
            entry_capacity,
            block_capacity,
        );
    }

    pub fn buildFindingCardFrameForState(
        self: View,
        allocator: std.mem.Allocator,
        state: finding_card.State,
    ) !?FindingCardFrame {
        if (self.view().effectiveDisplayMode() != .unified) return null;
        const loaded = self.view().activeLoadedDiffConst() orelse return null;
        const file_index = self.view().selectedFileIndex(loaded) orelse return null;
        if (!loaded.fileTextSelectable(file_index)) return null;
        const pinned = self.page.pinnedAiConst() orelse return null;
        const index = &pinned.selection.finding_projection;
        if (file_index >= index.files.len or file_index >= loaded.document.files.len) return null;
        const file = loaded.document.files[file_index];
        const folded = loaded.foldedHunksForFile(file_index);
        const line_index = loaded.cachedRenderedLineIndex(file_index, .unified) orelse
            loaded.renderedLineIndex(file_index, .unified);

        var models: std.ArrayList(finding_card.FindingCardModel) = .empty;
        defer models.deinit(allocator);
        for (index.files[file_index].mapped_entry_indices) |entry_index| {
            const model = finding_card.FindingCardModel.init(index, entry_index) orelse continue;
            if (model.span.file_ordinal != file_index) continue;
            if (self.page.contentForFindingCard(model) == null) continue;
            try appendResolvedFindingCardModel(allocator, &models, file, folded, line_index, model);
        }
        if (models.items.len == 0) return null;

        var row_plan = try finding_card.RowPlan.build(
            allocator,
            models.items,
            folded,
        );
        errdefer row_plan.deinit(allocator);
        if (row_plan.cards.len == 0) return null;

        var inputs: std.ArrayList(diff_render.InlineBlockInput) = .empty;
        defer inputs.deinit(allocator);
        for (row_plan.groups) |group| {
            const source_offset = diff_view_model.renderedOffsetForCoordinate(file, .unified, .{ .hunk_line = .{
                .hunk_index = group.hunk_ordinal,
                .line_index = group.last_diff_line_ordinal,
            } }, folded, line_index) orelse continue;
            for (group.card_start..group.card_start + group.card_count) |card_index| {
                try inputs.append(allocator, .{
                    .after_source_offset = source_offset,
                    .height = state.cardRows(row_plan.cards[card_index]),
                    .kind = .{ .card = card_index },
                });
            }
            try inputs.append(allocator, .{
                .after_source_offset = source_offset,
                .height = finding_card.group_spacer_rows,
                .kind = .spacer,
            });
        }
        if (inputs.items.len == 0) return null;
        var presentation_rows = try diff_render.PresentationRows.init(
            allocator,
            line_index.lineCount(),
            inputs.items,
        );
        errdefer presentation_rows.deinit(allocator);
        return .{ .row_plan = row_plan, .presentation_rows = presentation_rows };
    }

    /// Allocation-free lifecycle check used after shared navigation mutates
    /// file, fold, or display-mode state.
    pub fn focusedFindingCardVisible(self: View) bool {
        if (!self.page.finding_card.isFocused()) return true;
        if (self.view().effectiveDisplayMode() != .unified) return false;
        const loaded = self.view().activeLoadedDiffConst() orelse return false;
        const file_index = self.view().selectedFileIndex(loaded) orelse return false;
        if (!loaded.fileTextSelectable(file_index)) return false;
        const pinned = self.page.pinnedAiConst() orelse return false;
        if (file_index >= pinned.selection.finding_projection.files.len) return false;
        const folded = loaded.foldedHunksForFile(file_index);
        const file = loaded.document.files[file_index];
        const line_index = loaded.cachedRenderedLineIndex(file_index, .unified) orelse
            loaded.renderedLineIndex(file_index, .unified);
        const file_record = pinned.selection.finding_projection.files[file_index];
        for (file_record.mapped_entry_indices) |entry_index| {
            const model = finding_card.FindingCardModel.init(&pinned.selection.finding_projection, entry_index) orelse continue;
            if (model.span.file_ordinal != file_index) continue;
            if (model.span.hunk_ordinal < folded.len and folded[model.span.hunk_ordinal]) continue;
            if (self.page.finding_card.matches(model) and
                self.page.contentForFindingCard(model) != null and
                sourceOffsetForModel(file, folded, line_index, model) != null) return true;
        }
        return false;
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
    presentation_rows: ?*const diff_render.PresentationRows = null,

    fn sharedController(self: Controller) diff_surface.navigation.Controller {
        return .{
            .surface = self.page.diffSurface(source, self.layout),
            .repo_root = self.repo_root,
            .repo_epoch = self.repo_epoch,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
            .presentation_rows = self.presentation_rows,
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
            .presentation_rows = self.presentation_rows,
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
                .none, .installed => {},
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

pub const FindingCardFrame = struct {
    row_plan: finding_card.RowPlan,
    presentation_rows: diff_render.PresentationRows,

    pub fn deinit(self: *FindingCardFrame, allocator: std.mem.Allocator) void {
        self.presentation_rows.deinit(allocator);
        self.row_plan.deinit(allocator);
        self.* = undefined;
    }

    pub fn containsFocused(self: *const FindingCardFrame, state: finding_card.State) bool {
        if (!state.isFocused()) return false;
        for (self.presentation_rows.blocks) |block| switch (block.kind) {
            .card => |card_index| {
                if (card_index < self.row_plan.cards.len and state.matches(self.row_plan.cards[card_index])) return true;
            },
            .spacer => {},
        };
        return false;
    }
};

pub const PreparedFindingCardFrame = struct {
    row_plan: finding_card.RowPlan,
    presentation_rows: diff_render.PresentationRows,
};

pub const FindingCardFramePreparation = struct {
    pub const allocation_count: usize = 6;

    allocator: std.mem.Allocator,
    selection: *const review_store.SelectedRunRead,
    loaded: *const loaded_diff.LoadedDiff,
    models: []finding_card.FindingCardModel,
    groups: []finding_card.Group,
    cards: []finding_card.FindingCardModel,
    cursors: []usize,
    inputs: []diff_render.InlineBlockInput,
    blocks: []diff_render.InlineBlock,

    fn init(
        allocator: std.mem.Allocator,
        selection: *const review_store.SelectedRunRead,
        loaded: *const loaded_diff.LoadedDiff,
        entry_capacity: usize,
        block_capacity: usize,
    ) std.mem.Allocator.Error!FindingCardFramePreparation {
        const models = try allocator.alloc(finding_card.FindingCardModel, entry_capacity);
        errdefer allocator.free(models);
        const groups = try allocator.alloc(finding_card.Group, entry_capacity);
        errdefer allocator.free(groups);
        const cards = try allocator.alloc(finding_card.FindingCardModel, entry_capacity);
        errdefer allocator.free(cards);
        const cursors = try allocator.alloc(usize, entry_capacity);
        errdefer allocator.free(cursors);
        const inputs = try allocator.alloc(diff_render.InlineBlockInput, block_capacity);
        errdefer allocator.free(inputs);
        const blocks = try allocator.alloc(diff_render.InlineBlock, block_capacity);
        return .{
            .allocator = allocator,
            .selection = selection,
            .loaded = loaded,
            .models = models,
            .groups = groups,
            .cards = cards,
            .cursors = cursors,
            .inputs = inputs,
            .blocks = blocks,
        };
    }

    pub fn deinit(self: *FindingCardFramePreparation) void {
        self.allocator.free(self.blocks);
        self.allocator.free(self.inputs);
        self.allocator.free(self.cursors);
        self.allocator.free(self.cards);
        self.allocator.free(self.groups);
        self.allocator.free(self.models);
        self.* = undefined;
    }

    pub fn fill(
        self: *FindingCardFramePreparation,
        view: View,
        state: finding_card.State,
    ) ?PreparedFindingCardFrame {
        const loaded = view.view().activeLoadedDiffConst().?;
        const pinned = view.page.pinnedAiConst().?;
        std.debug.assert(loaded == self.loaded);
        std.debug.assert(&pinned.selection == self.selection);
        if (view.view().effectiveDisplayMode() != .unified) return null;
        const file_index = view.view().selectedFileIndex(loaded) orelse return null;
        if (!loaded.fileTextSelectable(file_index)) return null;
        const index = &pinned.selection.finding_projection;
        if (file_index >= index.files.len or file_index >= loaded.document.files.len) return null;
        const file = loaded.document.files[file_index];
        const folded = loaded.foldedHunksForFile(file_index);
        const line_index = loaded.cachedRenderedLineIndex(file_index, .unified) orelse
            loaded.renderedLineIndex(file_index, .unified);

        var model_count: usize = 0;
        for (index.files[file_index].mapped_entry_indices) |entry_index| {
            const model = finding_card.FindingCardModel.init(index, entry_index) orelse continue;
            if (model.span.file_ordinal != file_index or view.page.contentForFindingCard(model) == null) continue;
            if (sourceOffsetForModel(file, folded, line_index, model) == null) continue;
            std.debug.assert(model_count < self.models.len);
            self.models[model_count] = model;
            model_count += 1;
        }
        if (model_count == 0) return null;
        const row_plan = finding_card.RowPlan.buildPrepared(
            self.models[0..model_count],
            folded,
            self.groups,
            self.cards,
            self.cursors,
        );
        if (row_plan.cards.len == 0) return null;

        var input_count: usize = 0;
        for (row_plan.groups) |group| {
            const source_offset = sourceOffsetForModel(
                file,
                folded,
                line_index,
                row_plan.cards[group.card_start],
            ).?;
            for (group.card_start..group.card_start + group.card_count) |card_index| {
                self.inputs[input_count] = .{
                    .after_source_offset = source_offset,
                    .height = state.cardRows(row_plan.cards[card_index]),
                    .kind = .{ .card = card_index },
                };
                input_count += 1;
            }
            self.inputs[input_count] = .{
                .after_source_offset = source_offset,
                .height = finding_card.group_spacer_rows,
                .kind = .spacer,
            };
            input_count += 1;
        }
        std.debug.assert(input_count <= self.inputs.len);
        return .{
            .row_plan = row_plan,
            .presentation_rows = diff_render.PresentationRows.initPrepared(
                line_index.lineCount(),
                self.inputs[0..input_count],
                self.blocks,
            ),
        };
    }
};

fn sourceOffsetForModel(
    file: diff_parser.FileDiff,
    folded_hunks: []const bool,
    line_index: diff_view_model.RenderedLineIndex,
    model: finding_card.FindingCardModel,
) ?usize {
    return diff_view_model.renderedOffsetForCoordinate(file, .unified, .{ .hunk_line = .{
        .hunk_index = model.span.hunk_ordinal,
        .line_index = model.span.last_diff_line_ordinal,
    } }, folded_hunks, line_index);
}

fn appendResolvedFindingCardModel(
    allocator: std.mem.Allocator,
    models: *std.ArrayList(finding_card.FindingCardModel),
    file: diff_parser.FileDiff,
    folded_hunks: []const bool,
    line_index: diff_view_model.RenderedLineIndex,
    model: finding_card.FindingCardModel,
) std.mem.Allocator.Error!void {
    if (sourceOffsetForModel(file, folded_hunks, line_index, model) == null) return;
    try models.append(allocator, model);
}

test "Review Finding card frame admission omits unresolved coordinates and reports allocation failure" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/src/card.zig b/src/card.zig",
        .old_path = "a/src/card.zig",
        .new_path = "b/src/card.zig",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 1,
            .new_start = 1,
            .new_count = 2,
            .section = "cards",
            .lines = &.{
                .{ .kind = .context, .text = "one", .old_line = 1, .new_line = 1 },
                .{ .kind = .added, .text = "two", .new_line = 2 },
            },
        }},
    };
    var line_index = try diff_view_model.RenderedLineIndex.build(std.testing.allocator, file, .unified);
    defer line_index.deinit(std.testing.allocator);
    const valid: finding_card.FindingCardModel = .{
        .identity = std.mem.zeroes(finding_projection.Identity),
        .entry_index = 0,
        .finding_id = "valid",
        .span = .{ .file_ordinal = 0, .hunk_ordinal = 0, .first_diff_line_ordinal = 1, .last_diff_line_ordinal = 1 },
        .severity = .warning,
    };
    var unresolved = valid;
    unresolved.entry_index = 1;
    unresolved.finding_id = "unresolved";
    unresolved.span.last_diff_line_ordinal = 99;

    var models: std.ArrayList(finding_card.FindingCardModel) = .empty;
    defer models.deinit(std.testing.allocator);
    try appendResolvedFindingCardModel(std.testing.allocator, &models, file, &.{false}, line_index, valid);
    try appendResolvedFindingCardModel(std.testing.allocator, &models, file, &.{false}, line_index, unresolved);
    try std.testing.expectEqual(@as(usize, 1), models.items.len);
    try std.testing.expectEqual(@as(usize, 0), models.items[0].entry_index);
    var plan = try finding_card.RowPlan.build(std.testing.allocator, models.items, &.{false});
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), plan.cards.len);
    try std.testing.expectEqual(@as(usize, 0), plan.cards[0].entry_index);

    var failing_models: std.ArrayList(finding_card.FindingCardModel) = .empty;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, appendResolvedFindingCardModel(
        failing.allocator(),
        &failing_models,
        file,
        &.{false},
        line_index,
        valid,
    ));
    try std.testing.expectEqual(@as(usize, 0), failing_models.items.len);
}

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
        .presentation = .{ .normal = .{ .basis = .{
            .base = .{
                .full_ref = try allocator.dupe(u8, "refs/heads/main"),
                .display_name = try allocator.dupe(u8, "main"),
                .kind = .local,
            },
            .head_display = try allocator.dupe(u8, "topic"),
            .target = .{
                .object_format = .sha1,
                .source_kind = .branch_range,
                .base_oid = .{},
                .head_oid = .{},
                .diff_base_oid = .{},
            },
            .ahead_count = 1,
        } } },
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
        .copy_diff_selection => |copy| try std.testing.expectEqualStrings("one\ntwo\nnew\n", copy.text),
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
            .copy_diff_selection => |copy| try std.testing.expectEqualStrings(case.expected, copy.text),
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
        .presentation = .{ .normal = .{ .basis = .{
            .base = .{
                .full_ref = try allocator.dupe(u8, "refs/heads/main"),
                .display_name = try allocator.dupe(u8, "main"),
                .kind = .local,
            },
            .head_display = try allocator.dupe(u8, "topic"),
            .target = .{
                .object_format = .sha1,
                .source_kind = .branch_range,
                .base_oid = .{},
                .head_oid = .{},
                .diff_base_oid = .{},
            },
            .ahead_count = 1,
        } } },
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

    page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } };
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
    try std.testing.expect(page.pinned_selection_basis.?.eql(review_page.PinnedSelectionBasis.init(page.normalBasisConst().?.*)));
    var effect = copied.takeEffect() orelse return error.ExpectedSelectionEffect;
    defer effect.deinit(allocator);
    switch (effect) {
        .copy_diff_selection => |copy| try std.testing.expectEqualStrings("one\ntwo\nnew\n", copy.text),
        .copy_diff_header_path => return error.ExpectedSelectionEffect,
    }
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.completed_selection != null);
    const prior_pin = page.pinned_selection_basis.?;
    const prior_text = try page.completed_selection.?.clipboardText(allocator);
    defer allocator.free(prior_text);

    var second_begin = try adapter.shared().apply(null, .begin_keyboard_line_selection);
    second_begin.deinit(null);
    var second_choose = try adapter.shared().apply(null, .{ .choose_keyboard_selection_side = .new });
    second_choose.deinit(null);
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

    page.viewer.sidebar_hidden = false;
    page.viewer.focus = .diff;
    page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } };
    var focus_choice = try adapter.shared().apply(null, .begin_keyboard_line_selection);
    focus_choice.deinit(null);
    try std.testing.expect(page.selection_owner.activeKeyboardSideChoice() != null);
    var wheel_focus = try adapter.shared().apply(null, .mouse_sidebar_wheel_up);
    wheel_focus.deinit(null);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expectEqual(diff_surface.Focus.sidebar, page.viewer.focus);
}

test "Review retained candidate and pin replace transactionally and survive rejected installs" {
    const allocator = std.testing.allocator;
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .presentation = .{ .normal = .{ .basis = .{
            .base = .{
                .full_ref = try allocator.dupe(u8, "refs/heads/main"),
                .display_name = try allocator.dupe(u8, "main"),
                .kind = .local,
            },
            .head_display = try allocator.dupe(u8, "topic"),
            .target = .{
                .object_format = .sha1,
                .source_kind = .branch_range,
                .base_oid = .{},
                .head_oid = .{},
                .diff_base_oid = .{},
            },
            .ahead_count = 1,
        } } },
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
    page.normalBasis().?.target.head_oid.len = 1;
    page.normalBasis().?.target.head_oid.bytes[0] = 'c';
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
    try std.testing.expect(replacement_pin.eql(review_page.PinnedSelectionBasis.init(page.normalBasisConst().?.*)));

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
    const detached_presentation = page.presentation.?;
    page.presentation = null;
    defer if (page.presentation == null) {
        page.presentation = detached_presentation;
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
    page.presentation = detached_presentation;
}
