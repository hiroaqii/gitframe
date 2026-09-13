//! Presentation of evidence already owned by an exact retained job.
const std = @import("std");
const job = @import("../ai_review/job.zig");
const diagnostic = @import("../ai_review/diagnostic.zig");
const pipeline = @import("../ai_review/runner.zig");

pub const Selection = struct { key: job.Key, scroll: usize = 0 };
pub const Action = enum { open, close, up, down, page_up, page_down, home, end };

pub fn cause(phase: job.Phase) ?[]const u8 {
    const terminal = switch (phase) {
        .terminal => |value| value,
        .queued, .reviewing, .publishing => return null,
    };
    const failure = switch (terminal) {
        .start_failed => |value| return if (value == .review_task_start_failed) "review start failed" else "save start failed",
        .pipeline => |value| switch (value.outcome) {
            .failed => |failure| failure,
            .published, .no_changes, .canceled, .outcome_unknown => return null,
        },
    };
    return switch (failure) {
        .repository_unavailable => "repository unavailable",
        .target_unavailable => "target unavailable",
        .projection_failed => "projection failed",
        .input_failed => "input generation failed",
        .input_too_large => "input too large",
        .stream_too_large => |limit| if (limit.resource == .stderr_bytes) "stderr too large" else "stdout too large",
        .final_answer_too_large => "answer too large",
        .timed_out => "timed out",
        .provider_unavailable => |reason| switch (reason) {
            .private_environment => "provider setup failed",
            .executable_missing => "executable not found",
            .executable_denied => "executable denied",
            .launch_failed => "launch failed",
        },
        .provider_incompatible => "CLI incompatible",
        .provider_failed => "provider I/O failed",
        .provider_exit => |value| switch (value.classification) {
            .authentication_response => "auth-related response",
            .cli_response => "CLI incompatible",
            .other => "provider exited",
        },
        .invalid_provider_result => |stage| if (stage == .input) "invalid review input" else "invalid answer",
        .invalid_candidates => "invalid candidates",
        .store_prepare_failed => |store_cause| storeCauseLabel(store_cause),
        .artifact_failed => "artifact creation failed",
        .publish_failed => |store_cause| storeCauseLabel(store_cause),
        .exact_reconciliation_failed => "save verification failed",
        .internal_error => "internal error",
    };
}

/// All inputs have fixed bounds; no provider text, paths, or prompt is retained.
pub fn format(buffer: *[2048]u8, record: *const job.Record) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    switch (record.phase) {
        .terminal => |terminal| switch (terminal) {
            .start_failed => |failure| {
                writer.print("Failed: {s}\n", .{cause(record.phase).?}) catch unreachable;
                formatStartFailure(&writer, failure);
            },
            .pipeline => |pipeline_terminal| switch (pipeline_terminal.outcome) {
                .failed => |failure| {
                    writer.print("Failed: {s}\n", .{cause(record.phase).?}) catch unreachable;
                    formatFailure(&writer, failure);
                },
                .canceled => writer.writeAll("Canceled by user.\n") catch unreachable,
                .outcome_unknown => |review_id| {
                    const canonical = review_id.canonical();
                    writer.print(
                        "Outcome unknown.\nStage: Store publication or save verification\nReview ID: {s}\nNext: Reload AI Reviews and check this exact review ID before starting another review.\n",
                        .{&canonical},
                    ) catch unreachable;
                },
                .published => |published| {
                    const canonical = published.review_id.canonical();
                    writer.print("Published review {s} with {d} findings.\n", .{ &canonical, published.finding_count }) catch unreachable;
                },
                .no_changes => writer.writeAll("Completed with no changes.\n") catch unreachable,
            },
        },
        .queued, .reviewing, .publishing => writer.writeAll("AI review is still running.\n") catch unreachable,
    }
    writer.print("\nJob: {d} (generation {d})\nRepository: {s}\nPhysical identity: {d}:{d}\nBase: {s}\n{s}\nHead: {s}\n{s}", .{
        record.key.id,                        record.key.generation,         record.display.repository.slice(),
        record.scope.repository.device,       record.scope.repository.inode, record.display.base.slice(),
        record.scope.target.base_oid.slice(), record.display.head.slice(),   record.scope.target.head_oid.slice(),
    }) catch unreachable;
    return writer.buffered();
}

fn formatLimit(writer: *std.Io.Writer, maybe_limit: ?diagnostic.Limit) void {
    const limit = maybe_limit orelse {
        writer.writeAll("Limit / observation: unknown\n") catch unreachable;
        return;
    };
    const unit = switch (limit.resource.unit()) {
        .bytes => "bytes",
        .count => "count",
        .unknown => "(unit unknown)",
    };
    writer.print("Resource: {s}\nLimit: {d} {s}", .{ @tagName(limit.resource), limit.allowed, unit }) catch unreachable;
    if (limit.resource.unit() == .bytes and limit.allowed % 1024 == 0)
        writer.print(" ({d} KiB)", .{limit.allowed / 1024}) catch unreachable;
    writer.print("\nObserved{s}: {d} {s}\n", .{ if (limit.observation == .at_least) " at least" else "", limit.observed, unit }) catch unreachable;
}

fn formatFailure(writer: *std.Io.Writer, failure: pipeline.FailureCode) void {
    switch (failure) {
        .repository_unavailable => writer.writeAll("Stage: Before Codex starts\nNext: Reload the repository and review target.\n") catch unreachable,
        .target_unavailable => writer.writeAll("Stage: Before Codex starts\nNext: Restore or reload the fixed review target.\n") catch unreachable,
        .projection_failed => writer.writeAll("Stage: Before Codex starts\nNext: Reload the review target and check repository data.\n") catch unreachable,
        .input_failed => writer.writeAll("Stage: Before Codex starts\nNext: Check the review target and Context, then reduce the range if needed.\n") catch unreachable,
        .input_too_large => |limit| {
            writer.writeAll("Stage: Before Codex starts\n") catch unreachable;
            formatLimit(writer, limit);
            writer.writeAll("Next: Reduce the review range or Context.\n") catch unreachable;
            if (limit) |value| if (value.resource == .provider_input_bytes) {
                writer.writeAll("Config: [ai_review].max_input_bytes (generated prompt bytes). Provider limits still apply.\n") catch unreachable;
            };
        },
        .stream_too_large, .final_answer_too_large => |limit| {
            writer.print("Stage: {s}\n", .{if (failure == .stream_too_large) "Provider execution" else "Answer decoding"}) catch unreachable;
            formatLimit(writer, limit);
            writer.writeAll("Next: Reduce the review range; check provider output.\n") catch unreachable;
            switch (limit.resource) {
                .stdout_bytes => writer.writeAll("Config: [ai_review].max_stream_output_bytes (stdout wire bytes).\n") catch unreachable,
                .final_answer_bytes => writer.writeAll("Config: [ai_review].max_final_output_bytes (decoded whole answer; runtime ceiling 262144 bytes).\n") catch unreachable,
                else => {},
            }
        },
        .timed_out => |timing| {
            if (timing) |value| {
                writer.print("Stage: {s}\nBudget at entry: {f}\nDeadline owner: {s}\nScope: {s}\n", .{
                    switch (value.stage) {
                        .before_provider => "Before Codex starts",
                        .version_probe => "Version probe",
                        .provider_execution => "Provider execution",
                    },
                    value.budget,
                    @tagName(value.owner),
                    if (value.stage == .before_provider) "Remaining caller budget at pipeline entry" else "Adapter including version probe",
                }) catch unreachable;
            } else writer.writeAll("Stage / duration / deadline owner: unknown\n") catch unreachable;
            writer.writeAll("Next: Reduce the review range; check provider responsiveness.\n") catch unreachable;
            if (timing) |value| if (value.owner == .adapter) {
                writer.writeAll("Config: [ai_review].timeout_seconds (version probe through provider completion).\n") catch unreachable;
            };
        },
        .provider_unavailable => |reason| {
            writer.print("Stage: {s}\nNext: {s}\n", .{
                if (reason == .private_environment) "Before Codex starts" else "Process launch",
                if (reason == .private_environment) "Check temporary directory access." else "Check the configured executable path and permissions.",
            }) catch unreachable;
        },
        .provider_incompatible => |reason| {
            writer.print("Stage: {s}\nEvidence: {s}\nNext: Check Codex CLI compatibility.\n", .{
                if (reason == .environment or reason == .process_control) "Before Codex starts" else "Answer decoding", @tagName(reason),
            }) catch unreachable;
        },
        .provider_exit => |value| {
            writer.writeAll("Stage: Provider execution\n") catch unreachable;
            switch (value.term) {
                .exited => |code| writer.print("Exit code: {d}\n", .{code}) catch unreachable,
                .signal => |signal| writer.print("Signal: {d}\n", .{@intFromEnum(signal)}) catch unreachable,
                .stopped => |signal| writer.print("Stopped by signal: {d}\n", .{@intFromEnum(signal)}) catch unreachable,
                .unknown => |code| writer.print("Unknown termination status: {d}\n", .{code}) catch unreachable,
            }
            writer.writeAll(switch (value.classification) {
                .authentication_response => "Evidence: Authentication-related response; cause is not confirmed.\nNext: Check Codex login and provider access.\n",
                .cli_response => "Evidence: CLI option/configuration-related response.\nNext: Check Codex CLI compatibility.\n",
                .other => "Next: Check the provider and its exit status.\n",
            }) catch unreachable;
        },
        .invalid_provider_result => |stage| writer.writeAll(if (stage == .input)
            "Stage: Before Codex starts\nNext: Check review input and Context encoding.\n"
        else
            "Stage: Answer decoding\nThe answer was not accepted.\nNext: Check Codex CLI output and compatibility.\n") catch unreachable,
        .provider_failed => writer.writeAll("Stage: Provider execution\nNext: Check provider I/O and process availability.\n") catch unreachable,
        .invalid_candidates => writer.writeAll("Stage: Candidate validation\nThe answer was not accepted.\nNext: Reload the fixed target and check provider output.\n") catch unreachable,
        .store_prepare_failed => |store_cause| formatStoreFailure(
            writer,
            "Store preparation",
            "No review was saved.",
            store_cause,
        ),
        .artifact_failed => writer.writeAll("Stage: Artifact creation\nThe answer was not published.\nNext: Reload the fixed target and check repository data.\n") catch unreachable,
        .publish_failed => |store_cause| formatStoreFailure(
            writer,
            "Store publication",
            "The final save state could not be confirmed.",
            store_cause,
        ),
        .exact_reconciliation_failed => writer.writeAll("Stage: Save verification\nThe review result could not be verified against the expected metadata.\nNext: Reload AI Reviews and inspect the Store.\n") catch unreachable,
        .internal_error => |stage| {
            writer.print("Stage: {s}\nNext: Check available memory and runtime resources.\n", .{
                if (stage == .before_provider) "Before Codex starts" else "Unknown",
            }) catch unreachable;
        },
    }
}

fn storeCauseLabel(value: diagnostic.StoreCause) []const u8 {
    return switch (value) {
        .invalid_artifact => "invalid review artifacts",
        .target_unavailable => "target unavailable",
        .store_unavailable => "review store unavailable",
        .unsupported_platform => "review store platform unsupported",
        .unsupported_filesystem => "review store filesystem unsupported",
        .duplicate_review_id => "duplicate review ID",
        .store_invalid => "review store invalid",
        .repository_invalid => "repository invalid",
        .main_worktree_unavailable => "main worktree unavailable",
        .repository_name_invalid => "repository name invalid",
        .repository_namespace_collision => "repository namespace collision",
        .target_label_invalid => "target label invalid",
        .local_time_unavailable => "local time unavailable",
        .run_name_collision => "review Run name collision",
        .git_failed => "Git verification failed",
        .io_failed => "review store I/O failed",
        .binding_mismatch => "repository binding mismatch",
        .concurrent_conflict => "review store changed concurrently",
    };
}

fn formatStoreFailure(
    writer: *std.Io.Writer,
    stage: []const u8,
    outcome: []const u8,
    store_cause: diagnostic.StoreCause,
) void {
    writer.print("Stage: {s}\nCause: {s}\n{s}\nNext: {s}\n", .{
        stage,
        storeCauseLabel(store_cause),
        outcome,
        switch (store_cause) {
            .main_worktree_unavailable => "Check Git worktree metadata and the main worktree.",
            .repository_name_invalid => "Use a valid UTF-8 main-worktree directory name within the Store component limit.",
            .repository_namespace_collision => "Inspect the conflicting Store namespace and registry; do not overwrite it.",
            .target_label_invalid => "Use a valid saved target label; an invalid present label is not replaced or shortened.",
            .local_time_unavailable => "Check local timezone availability before starting another review.",
            .run_name_collision => "Inspect the conflicting Run entry; do not overwrite it or retry with another ID.",
            .unsupported_platform, .unsupported_filesystem => "Use a supported local Review Store platform and filesystem.",
            .repository_invalid, .git_failed, .target_unavailable => "Reload the repository and fixed review target.",
            .invalid_artifact => "Reload the fixed target and verify the generated review artifacts.",
            .duplicate_review_id => "Reload AI Reviews and inspect this review ID before starting another review.",
            .binding_mismatch, .concurrent_conflict => "Reload AI Reviews and verify the repository binding before retrying.",
            .store_invalid => "Inspect the configured Review Store without modifying unknown entries.",
            .store_unavailable, .io_failed => "Check the configured Store destination and permissions.",
        },
    }) catch unreachable;
}

fn formatStartFailure(writer: *std.Io.Writer, failure: job.StartFailure) void {
    writer.print("Stage: {s}\nNext: Check available runtime resources.\n", .{
        if (failure == .review_task_start_failed) "Review task start" else "Save task start",
    }) catch unreachable;
}
