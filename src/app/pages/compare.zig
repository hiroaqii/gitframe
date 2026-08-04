//! Retained state owner for the read-only Compare page.
//!
//! S3 installs the page identity and independent state skeleton. Loading,
//! picker ownership, committed-diff rendering, and page-local input are wired
//! by S4-S6; until then the shell renders the explicit not-loaded placeholder.

const std = @import("std");
const app_state = @import("../state.zig");
const diff_basis = @import("../diff_basis.zig");
const diff_surface = @import("../diff_surface.zig");
const load_state = @import("../load_state.zig");
const page = @import("../page.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_source = @import("../../diff/source.zig");
const file_tree = @import("../../file_tree.zig");
const review_state = @import("../../review/state.zig");

/// S6 replaces this scaffold with the owned asynchronous picker state.
pub const BasePickerState = struct {};

/// S5 replaces this scaffold with the owned Compare completion bundle.
pub const DeferredLoadApply = struct {};

pub const BasisFailureState = struct {
    kind: diff_basis.BasisFailure,
    attempted: diff_basis.BaseTarget,

    pub fn deinit(self: *BasisFailureState, allocator: std.mem.Allocator) void {
        self.attempted.deinit(allocator);
        self.* = undefined;
    }
};

pub const ComparePageState = struct {
    // Independently owned fields exposed through DiffSurface.
    activation: diff_surface.authority.Lifecycle = .init(.compare),
    status: app_state.StatusMessage = .{},
    load: load_state.LoadRuntimeState = .{},
    viewer: diff_surface.ViewerState = .{},
    search: diff_surface.DiffSearchState = .{},
    file_search: diff_surface.file_search.State = .{},
    file_search_return_focus: diff_surface.Focus = .sidebar,
    accepted_sidebar_revision: u64 = 1,
    review_display: app_state.ReviewDisplayState = .{},
    reviewed_store: review_state.Store = .{},
    tree_order: file_tree.StableOrder = .{},
    tree_order_scope: ?[]u8 = null,
    selection_owner: diff_selection.Owner = .none,
    completed_selection: ?diff_surface.selection.CompletedSelection = null,
    source_session_revision: u64 = 0,
    pending_initial_first_visible_selection: bool = false,

    // Compare-owned basis and refresh state.
    basis: ?diff_basis.BranchDiffBasis = null,
    base_target: ?diff_basis.BaseTarget = null,
    basis_failure: ?BasisFailureState = null,
    base_picker: BasePickerState = .{},
    refresh_generation: u64 = 0,
    deferred_load_apply: ?DeferredLoadApply = null,
    refresh_anchor: ?diff_surface.ReloadAnchor = null,

    pub fn activate(self: *ComparePageState, repo_epoch: u64) u64 {
        return self.activation.activate(repo_epoch, .pending, .unavailable, .unavailable);
    }

    pub fn deactivate(self: *ComparePageState) void {
        self.activation.deactivate();
    }

    pub fn deinit(self: *ComparePageState, allocator: std.mem.Allocator) void {
        self.selection_owner = .none;
        if (self.completed_selection) |*selection| selection.deinit(allocator);
        // Candidate paths borrow the accepted load owner.
        self.file_search.deinit(allocator);
        self.load.clearCurrent(allocator);
        self.reviewed_store.deinit(allocator);
        self.tree_order.deinit(allocator);
        if (self.tree_order_scope) |scope| allocator.free(scope);
        if (self.refresh_anchor) |*anchor| anchor.deinit(allocator);
        if (self.basis) |*basis| basis.deinit(allocator);
        if (self.base_target) |*target| target.deinit(allocator);
        if (self.basis_failure) |*failure| failure.deinit(allocator);
        self.* = .{};
    }

    pub fn diffSurface(
        self: *ComparePageState,
        source: diff_source.SourceMode,
        layout: diff_surface.Layout,
    ) diff_surface.DiffSurface {
        return .{
            .activation = &self.activation,
            .status = &self.status,
            .load = &self.load,
            .viewer = &self.viewer,
            .search = &self.search,
            .file_search = &self.file_search,
            .file_search_return_focus = &self.file_search_return_focus,
            .accepted_sidebar_revision = &self.accepted_sidebar_revision,
            .review_display = &self.review_display,
            .reviewed_store = &self.reviewed_store,
            .tree_order = &self.tree_order,
            .tree_order_scope = &self.tree_order_scope,
            .selection_owner = &self.selection_owner,
            .completed_selection = &self.completed_selection,
            .source_session_revision = &self.source_session_revision,
            .pending_initial_first_visible_selection = &self.pending_initial_first_visible_selection,
            .reload_anchor = if (self.refresh_anchor) |*anchor| anchor else null,
            .live_drag_deferred_source = self.deferred_load_apply != null,
            .source = source,
            .layout = layout,
        };
    }

    pub fn readSurface(
        self: *const ComparePageState,
        source: diff_source.SourceMode,
        layout: diff_surface.Layout,
    ) diff_surface.ReadSurface {
        return .{
            .activation = &self.activation,
            .status = &self.status,
            .load = &self.load,
            .viewer = &self.viewer,
            .search = &self.search,
            .file_search = &self.file_search,
            .file_search_return_focus = &self.file_search_return_focus,
            .accepted_sidebar_revision = &self.accepted_sidebar_revision,
            .review_display = &self.review_display,
            .reviewed_store = &self.reviewed_store,
            .tree_order = &self.tree_order,
            .tree_order_scope = &self.tree_order_scope,
            .selection_owner = &self.selection_owner,
            .completed_selection = &self.completed_selection,
            .source_session_revision = &self.source_session_revision,
            .pending_initial_first_visible_selection = &self.pending_initial_first_visible_selection,
            .reload_anchor = if (self.refresh_anchor) |*anchor| anchor else null,
            .live_drag_deferred_source = self.deferred_load_apply != null,
            .source = source,
            .layout = layout,
        };
    }
};

test "Compare owns an independent shared diff surface state" {
    const allocator = std.testing.allocator;
    var state: ComparePageState = .{};
    defer state.deinit(allocator);

    var surface = state.diffSurface(.{ .range = "0000000..1111111" }, .{ .width = 80, .height = 24 });
    surface.viewer.diff_scroll = 7;
    surface.search.mode = true;

    try std.testing.expectEqual(@as(usize, 7), state.viewer.diff_scroll);
    try std.testing.expect(state.search.mode);
    try std.testing.expect(surface.viewer == &state.viewer);
    try std.testing.expect(surface.source == .range);
}

test "Compare activation uses its own retained lifecycle" {
    var state: ComparePageState = .{};
    const first = state.activate(9);
    state.deactivate();
    const second = state.activate(9);

    try std.testing.expect(first != 0);
    try std.testing.expectEqual(first + 1, second);
    try std.testing.expectEqual(page.Id.compare, state.activation.currentIdentity().?.origin);
}
