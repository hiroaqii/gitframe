//! AI Reviews adapter for committed-diff navigation plus Finding presentation.

const std = @import("std");
const ai_reviews_page = @import("../ai_reviews.zig");
const finding_card = @import("../../../ai_review/finding_card.zig");
const finding_projection = @import("../../../ai_review/finding_projection.zig");
const diff_surface = @import("../../diff_surface.zig");
const diff_parser = @import("../../../diff/parser.zig");
const diff_render = @import("../../../diff/render.zig");
const diff_selection = @import("../../../diff/selection.zig");
const diff_source = @import("../../../diff/source.zig");
const diff_view_model = @import("../../../diff/view_model.zig");
const loaded_diff = @import("../../../loaded_diff.zig");
const committed_review = @import("../../../committed_review.zig");
const review_store = @import("../../../review_store.zig");
const root_capability = @import("../../../repo/root_capability.zig");

const committed_diff_navigation = @import("../committed_diff/navigation.zig");

const source: diff_source.SourceMode = ai_reviews_page.selection_source;

const SidebarAnnotationWidthAdapter = struct {
    projection: *const finding_projection.FindingProjectionIndex,

    fn interface(self: *SidebarAnnotationWidthAdapter) diff_surface.navigation.SidebarAnnotationWidthResolver {
        return .{ .ctx = self, .resolve_fn = resolve };
    }

    fn resolve(ctx: *anyopaque, file_index: usize) u16 {
        const self: *SidebarAnnotationWidthAdapter = @ptrCast(@alignCast(ctx));
        if (file_index >= self.projection.files.len) return 0;
        const summary = self.projection.files[file_index].summary;
        return findingAnnotationDisplayWidth(summary.total, summary.mapped);
    }
};

fn findingAnnotationDisplayWidth(total: usize, mapped: usize) u16 {
    if (total == 0) return 0;
    const non_mapped = total -| mapped;
    const width = 1 + decimalDisplayWidth(total) + if (non_mapped > 0)
        2 + decimalDisplayWidth(non_mapped)
    else
        0;
    return @intCast(@min(width, @as(usize, std.math.maxInt(u16))));
}

fn decimalDisplayWidth(value: usize) usize {
    var remaining = value;
    var width: usize = 1;
    while (remaining >= 10) : (remaining /= 10) width += 1;
    return width;
}

/// Read-only AI Reviews adapter. Rendering and content inspection must construct
/// this value directly from a const page borrow; mutation authority belongs to
/// `Controller` below.
pub const View = struct {
    page: *const ai_reviews_page.AiReviewsPageState,
    repo_root: ?[]const u8,
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,
    layout: diff_surface.Layout,
    mode_toggle_hint_width: u16 = 0,
    presentation_rows: ?*const diff_render.PresentationRows = null,

    pub fn sharedView(self: View) committed_diff_navigation.View {
        return .{
            .diff = &self.page.diff,
            .activation = &self.page.activation,
            .status = &self.page.status,
            .current_target = self.page.currentTarget(),
            .repo_root = self.repo_root,
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
            .source = source,
            .layout = self.layout,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
            .presentation_rows = self.presentation_rows,
        };
    }

    pub fn view(self: View) diff_surface.navigation.View {
        return self.sharedView().view();
    }

    pub fn bodyView(self: View, adapter: *BodyResolverAdapter) diff_surface.navigation.BodyView {
        return self.sharedView().bodyView(adapter);
    }

    pub fn resolver(self: View) BodyResolverAdapter {
        return self.sharedView().resolver();
    }

    pub fn contentView(self: View, adapter: *BodyResolverAdapter) diff_surface.content.View {
        return self.sharedView().contentView(adapter);
    }

    pub fn withPresentationRows(self: View, rows: ?*const diff_render.PresentationRows) View {
        var result = self;
        result.presentation_rows = rows;
        return result;
    }

    pub fn findingCardAtCursor(self: View) bool {
        if (self.page.diff.viewer.focus != .diff) return false;
        const cursor = switch (self.page.diff.viewer.diff_cursor) {
            .hunk_line => |line| line,
            else => return false,
        };
        const shared_view = self.view();
        const mode = shared_view.effectiveDisplayMode();
        const loaded = shared_view.activeLoadedDiffConst() orelse return false;
        const file_index = shared_view.selectedFileIndex(loaded) orelse return false;
        if (!loaded.fileTextSelectable(file_index)) return false;
        const pinned = self.page.selectedRunConst() orelse return false;
        if (file_index >= pinned.selection.finding_projection.files.len) return false;
        const folded = loaded.foldedHunksForFile(file_index);
        if (cursor.hunk_index < folded.len and folded[cursor.hunk_index]) return false;
        if (file_index >= loaded.document.files.len) return false;
        const file = loaded.document.files[file_index];
        const line_index = loaded.cachedRenderedLineIndex(file_index, mode) orelse
            loaded.renderedLineIndex(file_index, mode);
        const cursor_source_offset = diff_view_model.renderedOffsetForCoordinate(
            file,
            mode,
            .{ .hunk_line = cursor },
            folded,
            line_index,
        ) orelse return false;
        const file_record = pinned.selection.finding_projection.files[file_index];
        for (file_record.mapped_entry_indices) |entry_index| {
            const model = finding_card.FindingCardModel.init(&pinned.selection.finding_projection, entry_index) orelse continue;
            if (model.span.file_ordinal != file_index) continue;
            if (sourceOffsetForModel(file, folded, line_index, mode, model) != cursor_source_offset) continue;
            if (self.page.contentForFindingCard(model) != null) return true;
        }
        return false;
    }

    pub fn findingCardRowWidth(self: View, model: finding_card.FindingCardModel) u16 {
        const shared_view = self.view();
        const width = shared_view.diffPaneWidth();
        return switch (shared_view.effectiveDisplayMode()) {
            .unified => width,
            .side_by_side => switch (model.side) {
                .before => diff_render.sideBySideGeometry(diff_render.bodyWidth(width)).old.width,
                .after => diff_render.sideBySideGeometry(diff_render.bodyWidth(width)).new.width,
            },
        };
    }

    pub fn buildFindingCardFrame(self: View, allocator: std.mem.Allocator) !?FindingCardFrame {
        return self.buildFindingCardFrameForState(allocator, self.page.finding_card);
    }

    pub fn findingPresentationKey(self: View) ?ai_reviews_page.FindingPresentationKey {
        const shared_view = self.view();
        _ = shared_view.activeLoadedDiffConst() orelse return null;
        const pinned = self.page.selectedRunConst() orelse return null;
        return .{
            .identity = pinned.selection.finding_projection.identity,
            .source_session_revision = self.page.diff.source_session_revision,
            .selected_target = self.page.diff.viewer.selected_target,
            .pane_width = shared_view.diffPaneWidth(),
            .mode = shared_view.effectiveDisplayMode(),
            .selection_layout_revision = self.page.diff.selection_layout_revision,
        };
    }

    /// Borrow the retained frame only when every existing layout authority
    /// still matches. A mismatch intentionally renders no Finding cards.
    pub fn cachedFindingCardFrame(self: View) ?FindingCardFrame {
        const key = self.findingPresentationKey() orelse return null;
        const pinned = self.page.selectedRunConst() orelse return null;
        const cache = if (pinned.finding_presentation_cache) |*value| value else return null;
        const cached_key = cache.frame_key orelse return null;
        if (!cached_key.eql(key)) return null;
        const frame = cache.frame orelse return null;
        return .{
            .row_plan = frame.row_plan,
            .presentation_rows = frame.presentation_rows,
            .owned = false,
        };
    }

    pub fn prepareFindingCardFrame(
        self: View,
        allocator: std.mem.Allocator,
    ) (std.mem.Allocator.Error || error{InvalidFindingCardPreparation})!?FindingCardFramePreparation {
        const loaded = self.view().activeLoadedDiffConst() orelse return null;
        const pinned = self.page.selectedRunConst() orelse return null;
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
        const shared_view = self.view();
        const mode = shared_view.effectiveDisplayMode();
        const loaded = shared_view.activeLoadedDiffConst() orelse return null;
        const file_index = shared_view.selectedFileIndex(loaded) orelse return null;
        if (!loaded.fileTextSelectable(file_index)) return null;
        const pinned = self.page.selectedRunConst() orelse return null;
        const index = &pinned.selection.finding_projection;
        if (file_index >= index.files.len or file_index >= loaded.document.files.len) return null;
        const file = loaded.document.files[file_index];
        const folded = loaded.foldedHunksForFile(file_index);
        const line_index = loaded.cachedRenderedLineIndex(file_index, mode) orelse
            loaded.renderedLineIndex(file_index, mode);

        var models: std.ArrayList(finding_card.FindingCardModel) = .empty;
        defer models.deinit(allocator);
        for (index.files[file_index].mapped_entry_indices) |entry_index| {
            const model = finding_card.FindingCardModel.init(index, entry_index) orelse continue;
            if (model.span.file_ordinal != file_index) continue;
            if (self.page.contentForFindingCard(model) == null) continue;
            try appendResolvedFindingCardModel(allocator, &models, file, folded, line_index, mode, model);
        }
        if (models.items.len == 0) return null;

        var row_plan = try finding_card.RowPlan.build(
            allocator,
            models.items,
            folded,
        );
        errdefer row_plan.deinit(allocator);
        if (row_plan.cards.len == 0) return null;

        const input_capacity = std.math.add(usize, row_plan.cards.len, row_plan.groups.len) catch
            return error.InvalidPresentation;
        const inputs = try allocator.alloc(diff_render.InlineBlockInput, input_capacity);
        defer allocator.free(inputs);
        const input_count = try fillFindingCardInputs(
            inputs,
            row_plan,
            file,
            folded,
            line_index,
            mode,
            state,
        );
        if (input_count == 0) return null;
        var presentation_rows = try diff_render.PresentationRows.init(
            allocator,
            line_index.lineCount(),
            inputs[0..input_count],
        );
        errdefer presentation_rows.deinit(allocator);
        return .{ .row_plan = row_plan, .presentation_rows = presentation_rows };
    }

    /// Allocation-free lifecycle check used after shared navigation mutates
    /// file, fold, or display-mode state.
    pub fn focusedFindingCardVisible(self: View) bool {
        if (!self.page.finding_card.isFocused()) return true;
        const shared_view = self.view();
        const mode = shared_view.effectiveDisplayMode();
        const loaded = shared_view.activeLoadedDiffConst() orelse return false;
        const file_index = shared_view.selectedFileIndex(loaded) orelse return false;
        if (!loaded.fileTextSelectable(file_index)) return false;
        const pinned = self.page.selectedRunConst() orelse return false;
        if (file_index >= pinned.selection.finding_projection.files.len) return false;
        const folded = loaded.foldedHunksForFile(file_index);
        const file = loaded.document.files[file_index];
        const line_index = loaded.cachedRenderedLineIndex(file_index, mode) orelse
            loaded.renderedLineIndex(file_index, mode);
        const file_record = pinned.selection.finding_projection.files[file_index];
        for (file_record.mapped_entry_indices) |entry_index| {
            const model = finding_card.FindingCardModel.init(&pinned.selection.finding_projection, entry_index) orelse continue;
            if (model.span.file_ordinal != file_index) continue;
            if (model.span.hunk_ordinal < folded.len and folded[model.span.hunk_ordinal]) continue;
            if (self.page.finding_card.matches(model) and
                self.page.contentForFindingCard(model) != null and
                sourceOffsetForModel(file, folded, line_index, mode, model) != null) return true;
        }
        return false;
    }

    pub fn captureAnchor(self: View, allocator: std.mem.Allocator) !?diff_surface.ReloadAnchor {
        return self.sharedView().captureAnchor(allocator);
    }
};

/// Mutable AI Reviews adapter used only by update/input integration.
pub const Controller = struct {
    page: *ai_reviews_page.AiReviewsPageState,
    repo_root: ?[]const u8,
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,
    layout: diff_surface.Layout,
    mode_toggle_hint_width: u16 = 0,
    presentation_rows: ?*const diff_render.PresentationRows = null,

    fn sharedController(
        self: Controller,
        sidebar_annotation_width_resolver: ?diff_surface.navigation.SidebarAnnotationWidthResolver,
    ) diff_surface.navigation.Controller {
        return (committed_diff_navigation.Controller{
            .diff = &self.page.diff,
            .activation = &self.page.activation,
            .status = &self.page.status,
            .current_target = self.page.currentTarget(),
            .repo_root = self.repo_root,
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
            .source = source,
            .layout = self.layout,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
            .presentation_rows = self.presentation_rows,
            .sidebar_annotation_width_resolver = sidebar_annotation_width_resolver,
        }).sharedController();
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

    /// Fill the one admitted selected-Run cache. Capacity and all fallible
    /// work were completed by the pinned acceptance transaction.
    pub fn ensureFindingPresentationCache(self: Controller) void {
        const read_view = self.view();
        const key = read_view.findingPresentationKey() orelse {
            if (self.page.selectedRun()) |pinned| {
                if (pinned.finding_presentation_cache) |*cache| cache.invalidateFrame();
            }
            return;
        };
        const loaded = read_view.view().activeLoadedDiffConst() orelse return;
        const pinned = self.page.selectedRun() orelse return;
        const cache = if (pinned.finding_presentation_cache) |*value| value else return;
        if (cache.frame_key) |cached_key| {
            if (cached_key.eql(key)) return;
        }

        cache.invalidateFrame();
        var preparation = FindingCardFramePreparation.initBorrowed(
            &pinned.selection,
            loaded,
            cache,
        );
        if (preparation.fill(read_view, self.page.finding_card)) |frame| {
            cache.frame = .{
                .row_plan = frame.row_plan,
                .presentation_rows = frame.presentation_rows,
            };
        }
        cache.frame_key = key;
    }

    /// Short-lived mutable adapter whose navigation and body resolver are
    /// constructed from the same AI Reviews page owner. Callers cannot pair a
    /// controller from one page with a resolver borrowed from another page.
    pub const UpdateAdapter = struct {
        navigation: Controller,
        resolver: BodyResolverAdapter,
        sidebar_annotation_width: ?SidebarAnnotationWidthAdapter,

        pub fn bodyController(self: *UpdateAdapter) diff_surface.navigation.BodyController {
            const sidebar_annotation_width_resolver = if (self.sidebar_annotation_width) |*adapter|
                adapter.interface()
            else
                null;
            return .{
                .controller = self.navigation.sharedController(sidebar_annotation_width_resolver),
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
            return self.navigation.page.diff.installPinnedSelectionBasis(self.navigation.page.currentTarget());
        }

        pub fn applyRetentionTransition(
            self: *UpdateAdapter,
            _: std.mem.Allocator,
            transition: diff_surface.update.RetentionTransition,
        ) void {
            switch (transition) {
                .none, .installed => {},
                .cleared => self.navigation.page.diff.pinned_selection_basis = null,
            }
        }
    };

    pub fn updateAdapter(self: Controller) UpdateAdapter {
        const pinned = self.page.selectedRunConst();
        return .{
            .navigation = self,
            .resolver = self.view().resolver(),
            .sidebar_annotation_width = if (pinned) |value|
                .{ .projection = &value.selection.finding_projection }
            else
                null,
        };
    }
};

pub const FindingCardFrame = struct {
    row_plan: finding_card.RowPlan,
    presentation_rows: diff_render.PresentationRows,
    owned: bool = true,

    pub fn deinit(self: *FindingCardFrame, allocator: std.mem.Allocator) void {
        if (self.owned) {
            self.presentation_rows.deinit(allocator);
            self.row_plan.deinit(allocator);
        }
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

    allocator: ?std.mem.Allocator,
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

    fn initBorrowed(
        selection: *const review_store.SelectedRunRead,
        loaded: *const loaded_diff.LoadedDiff,
        cache: *ai_reviews_page.FindingPresentationCache,
    ) FindingCardFramePreparation {
        return .{
            .allocator = null,
            .selection = selection,
            .loaded = loaded,
            .models = cache.models,
            .groups = cache.groups,
            .cards = cache.cards,
            .cursors = cache.cursors,
            .inputs = cache.inputs,
            .blocks = cache.blocks,
        };
    }

    pub fn deinit(self: *FindingCardFramePreparation) void {
        const allocator = self.allocator orelse {
            self.* = undefined;
            return;
        };
        allocator.free(self.blocks);
        allocator.free(self.inputs);
        allocator.free(self.cursors);
        allocator.free(self.cards);
        allocator.free(self.groups);
        allocator.free(self.models);
        self.* = undefined;
    }

    pub fn fill(
        self: *FindingCardFramePreparation,
        view: View,
        state: finding_card.State,
    ) ?PreparedFindingCardFrame {
        const loaded = view.view().activeLoadedDiffConst().?;
        const pinned = view.page.selectedRunConst().?;
        std.debug.assert(loaded == self.loaded);
        std.debug.assert(&pinned.selection == self.selection);
        const shared_view = view.view();
        const mode = shared_view.effectiveDisplayMode();
        const file_index = shared_view.selectedFileIndex(loaded) orelse return null;
        if (!loaded.fileTextSelectable(file_index)) return null;
        const index = &pinned.selection.finding_projection;
        if (file_index >= index.files.len or file_index >= loaded.document.files.len) return null;
        const file = loaded.document.files[file_index];
        const folded = loaded.foldedHunksForFile(file_index);
        const line_index = loaded.cachedRenderedLineIndex(file_index, mode) orelse
            loaded.renderedLineIndex(file_index, mode);

        var model_count: usize = 0;
        for (index.files[file_index].mapped_entry_indices) |entry_index| {
            const model = finding_card.FindingCardModel.init(index, entry_index) orelse continue;
            if (model.span.file_ordinal != file_index or view.page.contentForFindingCard(model) == null) continue;
            if (sourceOffsetForModel(file, folded, line_index, mode, model) == null) continue;
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

        const input_count = fillFindingCardInputs(
            self.inputs,
            row_plan,
            file,
            folded,
            line_index,
            mode,
            state,
        ) catch unreachable;
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
    mode: diff_render.DisplayMode,
    model: finding_card.FindingCardModel,
) ?usize {
    if (model.span.hunk_ordinal >= file.hunks.len or
        (model.span.hunk_ordinal < folded_hunks.len and folded_hunks[model.span.hunk_ordinal])) return null;
    const hunk = file.hunks[model.span.hunk_ordinal];
    if (model.span.last_diff_line_ordinal >= hunk.lines.len) return null;
    if (mode == .side_by_side and diff_view_model.sideBySideRenderedOffsetForLineOnSide(
        hunk.lines,
        model.span.last_diff_line_ordinal,
        findingCardSide(model),
    ) == null) return null;
    return diff_view_model.renderedOffsetForCoordinate(file, mode, .{ .hunk_line = .{
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
    mode: diff_render.DisplayMode,
    model: finding_card.FindingCardModel,
) std.mem.Allocator.Error!void {
    if (sourceOffsetForModel(file, folded_hunks, line_index, mode, model) == null) return;
    try models.append(allocator, model);
}

fn findingCardSide(model: finding_card.FindingCardModel) diff_selection.Side {
    return switch (model.side) {
        .before => .old,
        .after => .new,
    };
}

fn findingCardPlacement(mode: diff_render.DisplayMode, model: finding_card.FindingCardModel) diff_render.InlineBlockPlacement {
    if (mode == .unified) return .full;
    return switch (findingCardSide(model)) {
        .old => .old,
        .new => .new,
    };
}

fn fillFindingCardInputs(
    storage: []diff_render.InlineBlockInput,
    row_plan: finding_card.RowPlan,
    file: diff_parser.FileDiff,
    folded_hunks: []const bool,
    line_index: diff_view_model.RenderedLineIndex,
    mode: diff_render.DisplayMode,
    state: finding_card.State,
) error{InvalidPresentation}!usize {
    var input_count: usize = 0;
    var previous_source_offset: ?usize = null;
    while (true) {
        var next_source_offset: ?usize = null;
        for (row_plan.cards) |model| {
            const source_offset = sourceOffsetForModel(file, folded_hunks, line_index, mode, model) orelse
                return error.InvalidPresentation;
            if (previous_source_offset) |previous| if (source_offset <= previous) continue;
            if (next_source_offset == null or source_offset < next_source_offset.?) next_source_offset = source_offset;
        }
        const source_offset = next_source_offset orelse break;
        for (row_plan.cards, 0..) |model, card_index| {
            if (sourceOffsetForModel(file, folded_hunks, line_index, mode, model).? != source_offset) continue;
            if (input_count >= storage.len) return error.InvalidPresentation;
            storage[input_count] = .{
                .after_source_offset = source_offset,
                .height = state.cardRows(model),
                .kind = .{ .card = card_index },
                .placement = findingCardPlacement(mode, model),
            };
            input_count += 1;
        }
        if (input_count >= storage.len) return error.InvalidPresentation;
        storage[input_count] = .{
            .after_source_offset = source_offset,
            .height = finding_card.group_spacer_rows,
            .kind = .spacer,
        };
        input_count += 1;
        previous_source_offset = source_offset;
    }
    return input_count;
}

pub const BodyResolverAdapter = committed_diff_navigation.BodyResolverAdapter;

test "AI Reviews navigation keeps const view and mutable controller authority separate" {
    const view_page = @typeInfo(@FieldType(View, "page")).pointer;
    const controller_page = @typeInfo(@FieldType(Controller, "page")).pointer;
    try std.testing.expect(view_page.is_const);
    try std.testing.expect(!controller_page.is_const);
}
