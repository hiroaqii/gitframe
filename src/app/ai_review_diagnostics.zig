//! Presentation of evidence already owned by an exact retained job.
const std = @import("std");
const job = @import("../ai_review/job.zig");
const diagnostic = @import("../ai_review/diagnostic.zig");
const pipeline = @import("../ai_review/runner.zig");

pub const Selection = struct { key: job.Key, scroll: usize = 0 };
pub const Action = enum { open, close, up, down, page_up, page_down, home, end };

pub fn cause(phase: job.Phase) ?[]const u8 {
    if (phase != .terminal or phase.terminal != .pipeline or phase.terminal.pipeline.outcome != .failed) return null;
    return switch (phase.terminal.pipeline.outcome.failed) {
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
        else => null,
    };
}

/// All inputs have fixed bounds; no provider text, paths, or prompt is retained.
pub fn format(buffer: *[2048]u8, record: *const job.Record) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    if (cause(record.phase)) |summary| {
        writer.print("Failed: {s}\n", .{summary}) catch unreachable;
        formatFailure(&writer, record.phase.terminal.pipeline.outcome.failed);
    } else if (record.phase == .terminal and record.phase.terminal == .pipeline and record.phase.terminal.pipeline.outcome == .canceled) {
        writer.writeAll("Canceled by user.\n") catch unreachable;
    } else {
        // Later slices add evidence at each producer; do not infer it here.
        writer.writeAll("AI review terminal\n") catch unreachable;
        if (record.phase == .terminal) switch (record.phase.terminal) {
            .start_failed => |failure| writer.print("Result: {s}\n", .{@tagName(failure)}) catch unreachable,
            .pipeline => |terminal| {
                writer.print("Result: {s}\n", .{@tagName(terminal.outcome)}) catch unreachable;
                if (terminal.outcome == .failed)
                    writer.print("Cause: {s}\n", .{@tagName(terminal.outcome.failed)}) catch unreachable;
            },
        };
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
        .input_too_large => |limit| {
            writer.writeAll("Stage: Before Codex starts\n") catch unreachable;
            formatLimit(writer, limit);
            writer.writeAll("Next: Reduce the review range or Context.\n") catch unreachable;
        },
        .stream_too_large, .final_answer_too_large => |limit| {
            writer.print("Stage: {s}\n", .{if (failure == .stream_too_large) "Provider execution" else "Answer decoding"}) catch unreachable;
            formatLimit(writer, limit);
            writer.writeAll("Next: Reduce the review range; check provider output.\n") catch unreachable;
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
        else => {},
    }
}
