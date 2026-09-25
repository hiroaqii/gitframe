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
const history_page = @import("pages/history.zig");
const changes_page = @import("pages/changes.zig");
const changes_content = @import("pages/changes/content.zig");
const changes_navigation = @import("pages/changes/navigation.zig");
const changes_reload = @import("pages/changes/reload.zig");
const changes_authority = @import("diff_surface/authority.zig");
const diff_source = @import("../diff/source.zig");

pub const ShellBlockers = struct {
    help: bool = false,
    commit_input: bool = false,
    confirmation: bool = false,
    branch_switch: bool = false,
    remote_error: bool = false,
    git_action: bool = false,
    foreground_command: bool = false,
    teardown: bool = false,
};

pub const Intent = enum {
    none,
    changes_revalidation,
    changes_repository_changed,
    history_refresh,
    compare_refresh,
};

pub const Controller = struct {
    active_page: *page.Id,
    changes: *changes_page.ChangesPageState,
    repository: *repository_page.RepositoryPageState,
    history: *history_page.HistoryPageState,
    compare: *compare_page.ComparePageState,
    config_page: *page.LazyPlaceholder,
    repo: repo_session.View,
    source: diff_source.SourceMode,
    body_size: chasen.Size,
    status: *app_state.StatusMessage,
    shell_blockers: ShellBlockers,

    pub fn activateChanges(self: Controller) u64 {
        const source_member: changes_authority.MemberFreshness = .pending;
        const has_repo = self.repo.activeRoot() != null;
        const auxiliary: changes_authority.MemberFreshness = if (diff_source.sourceRequiresRepo(self.source) and has_repo)
            .pending
        else
            .unavailable;
        return self.changes.activation.activate(self.repo.epoch(), source_member, auxiliary, auxiliary);
    }

    /// Re-establishes page-local activation after an accepted repository
    /// replacement, then tells root which read owner must run.
    pub fn acceptedRepositoryChange(self: Controller, allocator: std.mem.Allocator) Intent {
        return switch (self.active_page.*) {
            .changes => .changes_repository_changed,
            .compare => blk: {
                _ = self.compare.activate(self.repo.epoch());
                break :blk .compare_refresh;
            },
            .history => blk: {
                self.history.activate(allocator, self.repo.epoch(), self.repo.activeIdentity());
                break :blk .history_refresh;
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
        if (self.active_page.* == .changes and target == .repository) {
            var incoming = self.prepareChangesRepositoryHandoff(allocator) catch {
                self.status.set("could not prepare page navigation", .{});
                return .none;
            };
            var incoming_owned = true;
            defer if (incoming_owned) incoming.deinit(allocator);
            self.commitChangesRepositoryHandoff(allocator, &incoming);
            incoming_owned = false;
            return .none;
        }

        if (self.active_page.* == .repository and target == .changes) {
            self.commitRepositoryChangesHandoff(allocator);
            return .changes_revalidation;
        }

        if (self.active_page.* == .changes) self.deactivateChangesForPageSwitch(allocator);
        if (self.active_page.* == .repository) self.deactivateRepositoryForPageSwitch();
        if (self.active_page.* == .history) self.history.deactivate();
        if (self.active_page.* == .compare) self.compare.deactivate();
        self.active_page.* = target;
        return switch (target) {
            .changes => blk: {
                _ = self.activateChanges();
                break :blk .changes_revalidation;
            },
            .repository => blk: {
                self.repository.activate(self.repo.epoch(), self.repo.activeIdentity());
                break :blk .none;
            },
            .history => blk: {
                self.history.activate(allocator, self.repo.epoch(), self.repo.activeIdentity());
                break :blk .history_refresh;
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
        const active = self.active_page.*;
        return .{
            .changes_mouse_selection = active == .changes and self.changes.selection_owner.activeMouseSelection(),
            .history_mouse_selection = active == .history and self.history.diff.selection_owner.activeMouseSelection(),
            .compare_mouse_selection = active == .compare and self.compare.diff.selection_owner.activeMouseSelection(),
            .repository_mouse_selection = active == .repository and self.repository.activeMouseSourceRange(),
            .changes_deferred_apply = active == .changes and self.changes.deferredSourceBlocksPageTransition(),
            .compare_deferred_apply = active == .compare and self.compare.deferred_load_apply != null,
            .changes_search = active == .changes and self.changes.search.mode,
            .changes_file_search = active == .changes and self.changes.file_search.mode,
            .history_search = active == .history and self.history.diff.search.mode,
            .history_file_search = active == .history and self.history.diff.file_search.mode,
            .compare_search = active == .compare and self.compare.diff.search.mode,
            .compare_file_search = active == .compare and self.compare.diff.file_search.mode,
            .repository_source_search = active == .repository and self.repository.source_search.mode,
            .repository_file_search = active == .repository and self.repository.file_search.mode,
            .repo_picker = self.repo.picker().model.mode,
            .help = self.shell_blockers.help,
            .commit_input = self.shell_blockers.commit_input,
            .confirmation = self.shell_blockers.confirmation,
            .branch_switch = self.shell_blockers.branch_switch,
            .compare_base_picker = active == .compare and self.compare.base_picker.open,
            .remote_error = self.shell_blockers.remote_error,
            .git_action = self.shell_blockers.git_action,
            .foreground_command = self.shell_blockers.foreground_command,
            .teardown = self.shell_blockers.teardown,
        };
    }

    fn prepareChangesRepositoryHandoff(
        self: Controller,
        allocator: std.mem.Allocator,
    ) !page_link.RepositoryIncoming {
        const target = self.changesContent().repositoryTarget();
        if (target == .no_context) return .no_context;
        const root_identity = self.repo.activeIdentity() orelse return error.MissingRepositoryIdentity;
        return page_link.RepositoryIncoming.initOwned(
            allocator,
            self.repo.epoch(),
            root_identity,
            target,
        );
    }

    fn commitChangesRepositoryHandoff(
        self: Controller,
        allocator: std.mem.Allocator,
        incoming: *page_link.RepositoryIncoming,
    ) void {
        std.debug.assert(self.active_page.* == .changes);
        self.repository.acceptIncoming(allocator, incoming);
        self.deactivateChangesForPageSwitch(allocator);
        self.active_page.* = .repository;
        self.repository.activate(self.repo.epoch(), self.repo.activeIdentity());
        _ = self.repository.resolveIncomingAfterActivation(allocator, self.body_size);
    }

    fn commitRepositoryChangesHandoff(self: Controller, allocator: std.mem.Allocator) void {
        std.debug.assert(self.active_page.* == .repository);
        const target = self.repository.changesTarget();
        self.repository.dismissIncoming(allocator);
        self.deactivateRepositoryForPageSwitch();
        self.active_page.* = .changes;
        _ = self.activateChanges();

        switch (target) {
            .no_context => self.status.set("Repository has no resolved file to open in Changes", .{}),
            .location => |location| {
                const outcome = self.changesNavigation().revealExactPath(allocator, location) catch {
                    self.status.set("could not prepare page navigation", .{});
                    return;
                };
                switch (outcome) {
                    .selected => {},
                    .unchanged => self.status.set("Repository file is already selected in Changes", .{}),
                    .unavailable => |reason| self.status.set("{s}", .{reason.message()}),
                }
            },
        }
    }

    fn deactivateRepositoryForPageSwitch(self: Controller) void {
        self.repository.clearLiveSelectionPreservingViewport(self.body_size);
        self.repository.deactivate();
    }

    fn deactivateChangesForPageSwitch(self: Controller, allocator: std.mem.Allocator) void {
        std.debug.assert(self.active_page.* == .changes);
        std.debug.assert(!self.changes.deferredSourceBlocksPageTransition());
        self.changesReload().retireCanonicalPublicationForPageExit(allocator);
        self.changes.selection_owner = .none;
        self.changes.activation.deactivate();
    }

    fn changesNavigation(self: Controller) changes_navigation.Controller {
        return .{
            .page = self.changes,
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
            .source = self.source,
            .layout = self.diffLayout(),
            .diagnostics = .{ .target = &self.changes.status },
        };
    }

    fn changesNavigationView(self: Controller) changes_navigation.View {
        return .{
            .page = self.changes,
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
            .source = self.source,
            .layout = self.diffLayout(),
        };
    }

    fn changesContent(self: Controller) changes_content.View {
        return .{
            .page = self.changes,
            .navigation = self.changesNavigationView(),
            .source = self.source,
            .repo_root = self.repo.activeRoot(),
        };
    }

    fn changesReload(self: Controller) changes_reload.Controller {
        return .{
            .page = self.changes,
            .navigation = self.changesNavigation(),
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
    pub fn prepareChangesRepositoryHandoff(
        controller: Controller,
        allocator: std.mem.Allocator,
    ) !page_link.RepositoryIncoming {
        return controller.prepareChangesRepositoryHandoff(allocator);
    }

    pub fn commitChangesRepositoryHandoff(
        controller: Controller,
        allocator: std.mem.Allocator,
        incoming: *page_link.RepositoryIncoming,
    ) void {
        controller.commitChangesRepositoryHandoff(allocator, incoming);
    }

    pub fn commitRepositoryChangesHandoff(
        controller: Controller,
        allocator: std.mem.Allocator,
    ) void {
        controller.commitRepositoryChangesHandoff(allocator);
    }
} else struct {};
