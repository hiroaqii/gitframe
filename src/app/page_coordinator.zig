//! Shell-owned page activation and transition coordination.
//!
//! Keyboard, page-bar, and future callers enter one transition boundary. The
//! controller performs fallible handoff preparation before any page mutation,
//! commits activation changes synchronously, and returns typed cross-owner
//! intents for root to consume.

const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");
const app_state = @import("state.zig");
const diff_surface = @import("diff_surface.zig");
const page = @import("page.zig");
const page_link = @import("page_link.zig");
const page_transition = @import("page_transition.zig");
const repo_session = @import("repo_session.zig");
const compare_page = @import("pages/compare.zig");
const repository_page = @import("pages/repository.zig");
const review_page = @import("pages/review.zig");
const review_content = @import("pages/review/content.zig");
const review_navigation = @import("pages/review/navigation.zig");
const review_reload = @import("pages/review/reload.zig");
const review_authority = @import("diff_surface/authority.zig");
const diff_source = @import("../diff/source.zig");

pub const ShellBlockers = struct {
    help: bool = false,
    commit_input: bool = false,
    confirmation: bool = false,
    branch_switch: bool = false,
    push_error: bool = false,
    git_action: bool = false,
    foreground_command: bool = false,
    live_review_waiter: bool = false,
    teardown: bool = false,
};

pub const Intent = enum {
    none,
    review_revalidation,
    review_repository_changed,
    compare_refresh,
};

pub const Controller = struct {
    active_page: *page.Id,
    review: *review_page.ReviewPageState,
    repository: *repository_page.RepositoryPageState,
    compare: *compare_page.ComparePageState,
    config_page: *page.LazyPlaceholder,
    repo: repo_session.View,
    source: diff_source.SourceMode,
    body_size: chasen.Size,
    status: *app_state.StatusMessage,
    shell_blockers: ShellBlockers,

    pub fn activateReview(self: Controller) u64 {
        const source_member: review_authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(self.source))
            switch (self.review.load.state) {
                .loaded, .empty => .immutable,
                .loading => .pending,
                .failed => .failed,
                .idle => .pending,
            }
        else
            .pending;
        const has_repo = self.repo.activeRoot() != null;
        const auxiliary: review_authority.MemberFreshness = if (diff_source.sourceRequiresRepo(self.source) and has_repo)
            .pending
        else
            .unavailable;
        return self.review.activation.activate(self.repo.epoch(), source_member, auxiliary, auxiliary);
    }

    /// Re-establishes page-local activation after an accepted repository
    /// replacement, then tells root which read owner must run.
    pub fn acceptedRepositoryChange(self: Controller) Intent {
        return switch (self.active_page.*) {
            .review => .review_repository_changed,
            .compare => blk: {
                _ = self.compare.activate(self.repo.epoch());
                break :blk .compare_refresh;
            },
            .repository, .config => .none,
        };
    }

    pub fn requestSwitch(
        self: Controller,
        allocator: std.mem.Allocator,
        target: page.Id,
    ) Intent {
        // A header gesture borrows manifest path identity, while a source
        // range remains a real blocker. End only the former before policy.
        if (self.active_page.* == .repository and target != .repository) {
            _ = self.repository.cancelSourceHeaderOwner();
        }
        switch (page_transition.disposition(self.active_page.*, target, self.transitionSnapshot())) {
            .unchanged => {
                self.status.clearIfEphemeral();
                return .none;
            },
            .blocked => |blocker| {
                self.status.set("{s}", .{blocker.message()});
                return .none;
            },
            .allowed => {},
        }

        self.status.clearIfEphemeral();
        if (self.active_page.* == .review and target == .repository) {
            var incoming = self.prepareReviewRepositoryHandoff(allocator) catch {
                self.status.set("could not prepare page navigation", .{});
                return .none;
            };
            var incoming_owned = true;
            defer if (incoming_owned) incoming.deinit(allocator);
            self.commitReviewRepositoryHandoff(allocator, &incoming);
            incoming_owned = false;
            return .none;
        }

        if (self.active_page.* == .repository and target == .review) {
            self.commitRepositoryReviewHandoff(allocator);
            return .review_revalidation;
        }

        if (self.active_page.* == .review) self.deactivateReviewForPageSwitch(allocator);
        if (self.active_page.* == .repository) self.repository.deactivate();
        if (self.active_page.* == .compare) self.compare.deactivate();
        self.active_page.* = target;
        return switch (target) {
            .review => blk: {
                _ = self.activateReview();
                break :blk .review_revalidation;
            },
            .repository => blk: {
                self.repository.activate(self.repo.epoch(), self.repo.activeIdentity());
                break :blk .none;
            },
            .compare => blk: {
                _ = self.compare.activate(self.repo.epoch());
                break :blk .compare_refresh;
            },
            .config => blk: {
                self.config_page.ensureInitialized();
                break :blk .none;
            },
        };
    }

    fn transitionSnapshot(self: Controller) page_transition.Snapshot {
        return .{
            .review_mouse_selection = self.review.selection_owner.activeMouseSelection(),
            .compare_mouse_selection = self.compare.selection_owner.activeMouseSelection(),
            .repository_mouse_selection = self.repository.activeSourceRange(),
            .review_deferred_apply = self.review.deferredSourceBlocksPageTransition(),
            .compare_deferred_apply = self.compare.deferred_load_apply != null,
            .review_search = self.review.search.mode,
            .review_file_search = self.review.file_search.mode,
            .compare_search = self.compare.search.mode,
            .compare_file_search = self.compare.file_search.mode,
            .repository_source_search = self.repository.source_search.mode,
            .repository_file_search = self.repository.file_search.mode,
            .repo_picker = self.repo.picker().model.mode,
            .help = self.shell_blockers.help,
            .commit_input = self.shell_blockers.commit_input,
            .confirmation = self.shell_blockers.confirmation,
            .branch_switch = self.shell_blockers.branch_switch,
            .compare_base_picker = self.compare.base_picker.open,
            .push_error = self.shell_blockers.push_error,
            .git_action = self.shell_blockers.git_action,
            .foreground_command = self.shell_blockers.foreground_command,
            .live_review_waiter = self.shell_blockers.live_review_waiter,
            .teardown = self.shell_blockers.teardown,
        };
    }

    fn prepareReviewRepositoryHandoff(
        self: Controller,
        allocator: std.mem.Allocator,
    ) !page_link.RepositoryIncoming {
        const target = self.reviewContent().repositoryTarget();
        if (target == .no_context) return .no_context;
        const root_identity = self.repo.activeIdentity() orelse return error.MissingRepositoryIdentity;
        return page_link.RepositoryIncoming.initOwned(
            allocator,
            self.repo.epoch(),
            root_identity,
            target,
        );
    }

    fn commitReviewRepositoryHandoff(
        self: Controller,
        allocator: std.mem.Allocator,
        incoming: *page_link.RepositoryIncoming,
    ) void {
        std.debug.assert(self.active_page.* == .review);
        self.repository.acceptIncoming(allocator, incoming);
        self.deactivateReviewForPageSwitch(allocator);
        self.active_page.* = .repository;
        self.repository.activate(self.repo.epoch(), self.repo.activeIdentity());
        _ = self.repository.resolveIncomingAfterActivation(allocator, self.body_size);
    }

    fn commitRepositoryReviewHandoff(self: Controller, allocator: std.mem.Allocator) void {
        std.debug.assert(self.active_page.* == .repository);
        const target = self.repository.reviewTarget();
        self.repository.dismissIncoming(allocator);
        self.repository.deactivate();
        self.active_page.* = .review;
        _ = self.activateReview();

        switch (target) {
            .no_context => self.status.set("Repository has no resolved file to open in Review", .{}),
            .location => |location| {
                const outcome = self.reviewNavigation().revealExactPath(location) catch {
                    self.status.set("could not prepare page navigation", .{});
                    return;
                };
                switch (outcome) {
                    .selected => {},
                    .unchanged => self.status.set("Repository file is already selected in Review", .{}),
                    .unavailable => |reason| self.status.set("{s}", .{reason.message()}),
                }
            },
        }
    }

    fn deactivateReviewForPageSwitch(self: Controller, allocator: std.mem.Allocator) void {
        std.debug.assert(self.active_page.* == .review);
        std.debug.assert(!self.review.deferredSourceBlocksPageTransition());
        self.reviewReload().retireCanonicalPublicationForPageExit(allocator);
        self.review.selection_owner = .none;
        self.review.activation.deactivate();
    }

    fn reviewNavigation(self: Controller) review_navigation.Controller {
        return .{
            .page = self.review,
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
            .source = self.source,
            .layout = self.diffLayout(),
            .diagnostics = .{ .target = &self.review.status },
        };
    }

    fn reviewNavigationView(self: Controller) review_navigation.View {
        return .{
            .page = self.review,
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
            .source = self.source,
            .layout = self.diffLayout(),
        };
    }

    fn reviewContent(self: Controller) review_content.View {
        return .{
            .page = self.review,
            .navigation = self.reviewNavigationView(),
            .source = self.source,
            .repo_root = self.repo.activeRoot(),
        };
    }

    fn reviewReload(self: Controller) review_reload.Controller {
        return .{
            .page = self.review,
            .navigation = self.reviewNavigation(),
            .source = self.source,
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
        };
    }

    fn diffLayout(self: Controller) diff_surface.Layout {
        return .{ .width = self.body_size.width, .height = self.body_size.height };
    }
};

/// Narrow access to the fallible/infallible handoff boundary for owner-local
/// contract tests. Production callers enter through `requestSwitch`.
pub const testing = if (builtin.is_test) struct {
    pub fn prepareReviewRepositoryHandoff(
        controller: Controller,
        allocator: std.mem.Allocator,
    ) !page_link.RepositoryIncoming {
        return controller.prepareReviewRepositoryHandoff(allocator);
    }

    pub fn commitReviewRepositoryHandoff(
        controller: Controller,
        allocator: std.mem.Allocator,
        incoming: *page_link.RepositoryIncoming,
    ) void {
        controller.commitReviewRepositoryHandoff(allocator, incoming);
    }

    pub fn commitRepositoryReviewHandoff(
        controller: Controller,
        allocator: std.mem.Allocator,
    ) void {
        controller.commitRepositoryReviewHandoff(allocator);
    }
} else struct {};
