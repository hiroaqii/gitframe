//! Compare-owned admission boundary for one hosted AI review request.

const std = @import("std");
const compare_page = @import("../compare.zig");
const repo_session = @import("../../repo_session.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const ai_review_job = @import("../../../ai_review/job.zig");
const ai_review_jobs = @import("../../../ai_review/job_owner.zig");
const pipeline = @import("../../../ai_review/runner.zig");
const codex = @import("../../../ai_review/adapters/codex/adapter.zig");
const store_service = @import("../../../ai_review/store_service.zig");

pub const Failure = enum {
    codex_not_configured,
    store_not_configured,
    repository_missing,
    repository_authority_missing,
    repository_identity_missing,
    repository_changed,
    comparison_not_ready,
    comparison_changed,
    target_missing,
    target_changed,
    invalid_context,
    invalid_runner,
    request_failed,
    capacity,
    admission_closed,
    scope_mismatch,
    identity_exhausted,
};

pub const Outcome = union(enum) {
    ignored,
    accepted: ai_review_job.Key,
    rejected: Failure,
};

pub const Controller = struct {
    page: *compare_page.ComparePageState,
    repo: repo_session.View,
    store: ?*store_service.ConfiguredStore,
    codex_executable: ?[]const u8,
    codex_model: ?[]const u8,
    env_map: ?*std.process.Environ.Map,
    jobs: *ai_review_jobs.Owner,

    pub fn submit(self: Controller, allocator: std.mem.Allocator) Outcome {
        const modal = &self.page.ai_review_modal;
        if (!modal.open) return .ignored;
        modal.failure.clear();

        const executable = self.codex_executable orelse return reject(modal, .codex_not_configured);
        const store = self.store orelse return reject(modal, .store_not_configured);
        if (!store.isConfigured()) return reject(modal, .store_not_configured);

        const repository_path = self.repo.activeRoot() orelse return reject(modal, .repository_missing);
        const capability = self.repo.activeCapability() orelse return reject(modal, .repository_authority_missing);
        const repository = self.repo.activeIdentity() orelse return reject(modal, .repository_identity_missing);
        if (!capability.identity.eql(repository) or !root_capability.pathMatches(repository_path, repository)) {
            return reject(modal, .repository_changed);
        }

        const accepted_repository = self.page.diff.accepted_repository_identity orelse
            return reject(modal, .comparison_not_ready);
        if (!accepted_repository.matches(self.repo.epoch(), repository) or !self.page.hasAcceptedDisplay()) {
            return reject(modal, .comparison_changed);
        }
        const basis = self.page.basis orelse return reject(modal, .target_missing);
        const selected_base = self.page.base_target orelse return reject(modal, .target_missing);
        if (selected_base.kind != basis.base.kind or !std.mem.eql(u8, selected_base.full_ref, basis.base.full_ref)) {
            return reject(modal, .target_changed);
        }
        const target = basis.target;

        const review_context = modal.context.slice();
        if (review_context.len > compare_page.ai_review_context_capacity or
            !std.unicode.utf8ValidateSlice(review_context))
        {
            return reject(modal, .invalid_context);
        }

        const provider = codex.Request.init(allocator, executable, self.codex_model) catch
            return reject(modal, .invalid_runner);
        const request = pipeline.Request.init(
            allocator,
            capability.*,
            self.env_map,
            store,
            repository_path,
            target,
            .{ .base_label = basis.base.display_name, .head_label = basis.head_display },
            .{ .codex = provider },
            review_context,
        ) catch return reject(modal, .request_failed);

        const admission = self.jobs.enqueue(.{ .repository = repository, .target = target }, request);
        return switch (admission) {
            .accepted => |key| result: {
                self.page.closeAiReviewModal();
                break :result .{ .accepted = key };
            },
            .rejected => |reason| reject(modal, switch (reason) {
                .capacity => .capacity,
                .admission_closed => .admission_closed,
                .scope_mismatch => .scope_mismatch,
                .id_exhausted, .generation_exhausted => .identity_exhausted,
            }),
        };
    }
};

fn reject(modal: *compare_page.AiReviewModalState, failure: Failure) Outcome {
    modal.markFailure(switch (failure) {
        .codex_not_configured => "Configure [ai_review].codex_executable first",
        .store_not_configured => "Configure [ai_review].store_root first",
        .repository_missing => "Compare AI Review requires a repository",
        .repository_authority_missing => "Repository authority is unavailable",
        .repository_identity_missing => "Repository identity is unavailable",
        .repository_changed => "Repository changed; reload Compare before starting",
        .comparison_not_ready => "Comparison is not ready; reload before starting",
        .comparison_changed, .scope_mismatch => "Comparison changed; reload before starting",
        .target_missing => "Comparison target is unavailable",
        .target_changed => "Comparison target changed; reload before starting",
        .invalid_context => "Review context must be valid UTF-8 within 16 KiB",
        .invalid_runner => "Codex runner configuration is invalid",
        .request_failed => "Could not prepare immutable AI review request",
        .capacity => "AI review queue is full",
        .admission_closed => "AI review admission is closed",
        .identity_exhausted => "AI review job identity is exhausted",
    });
    return .{ .rejected = failure };
}
