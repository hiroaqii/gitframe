//! Changes-owned boundary for repository-session invalidation.
//!
//! The root assembles this short-lived adapter from Changes's navigation and
//! reload controllers. Repository-session coordination can then request only
//! the exact invalidations associated with an accepted repository identity.

const std = @import("std");
const diff_source = @import("../../../diff/source.zig");
const authority = @import("../../diff_surface/authority.zig");
const changes_page = @import("../changes.zig");
const navigation = @import("navigation.zig");
const reload = @import("reload.zig");

pub const Controller = struct {
    page: *changes_page.ChangesPageState,
    navigation: navigation.Controller,
    reload: reload.Controller,

    pub fn supersedeReads(self: Controller, allocator: std.mem.Allocator) void {
        self.reload.clearDeferredSourceApply(allocator);
        self.reload.clearDeferredProjectionApply(allocator);
        self.page.load.supersedePending();
        _ = self.page.status_load.prepare(false);
        _ = self.page.branch_status_load.prepare(false);
        self.page.auto_reload.supersedeCycle();
        self.page.changes_projection.clearPending(allocator);
        self.page.changes_projection.clearSyntaxPending(allocator);
    }

    pub fn invalidateBeforeReplacement(self: Controller, allocator: std.mem.Allocator) void {
        self.reload.clearPendingReload(allocator);
        self.navigation.clearActionCursor(allocator);
        self.reload.clearSourceDisplay(allocator);
        self.reload.dropStatusSnapshot(allocator);
        self.reload.invalidateBranchStatusSnapshot();
        self.navigation.resetAfterRepositorySwitch();
    }

    pub fn finishUnchangedExplicitSelection(self: Controller, allocator: std.mem.Allocator) void {
        const live_diff = if (self.page.load.pending) |pending|
            switch (pending) {
                .diff_load => true,
                .repo_discovery => false,
            }
        else
            false;
        if (!live_diff) self.reload.clearPendingReload(allocator);
        self.navigation.clearActionCursor(allocator);
    }

    /// An explicit same-identity selection wins over older repository
    /// discovery metadata without cancelling unrelated source/status reads.
    pub fn supersedeRepositoryDiscovery(self: Controller) void {
        const pending = self.page.load.pending orelse return;
        switch (pending) {
            .repo_discovery => {
                self.page.load.supersedePending();
                if (self.page.load.state == .loading) self.page.load.state = .idle;
                self.reload.failActiveMember(.source);
            },
            .diff_load => {},
        }
    }

    pub fn clearDiffSelection(self: Controller) void {
        self.navigation.clearDiffSelection();
    }

    pub fn commitIdentity(
        self: Controller,
        source: diff_source.SourceMode,
        repo_epoch: u64,
        active: bool,
        root_available: bool,
    ) void {
        self.page.status.clear();
        if (active) {
            const source_member: authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(source))
                switch (self.page.load.state) {
                    .loaded, .empty => .immutable,
                    .loading, .idle => .pending,
                    .failed => .failed,
                }
            else
                .pending;
            const auxiliary: authority.MemberFreshness = if (diff_source.sourceRequiresRepo(source) and root_available)
                .pending
            else
                .unavailable;
            _ = self.page.activation.activate(repo_epoch, source_member, auxiliary, auxiliary);
        } else {
            self.page.activation.deactivate();
        }
    }
};
