//! Presentation of evidence already owned by an exact retained job.
const std = @import("std");
const job = @import("../ai_review/job.zig");

pub const Selection = struct { key: job.Key, scroll: usize = 0 };
pub const Action = enum { open, close, up, down, page_up, page_down, home, end };

pub fn inputTooLarge(phase: job.Phase) bool {
    return phase == .terminal and phase.terminal == .pipeline and
        phase.terminal.pipeline.outcome == .failed and
        phase.terminal.pipeline.outcome.failed == .input_too_large;
}

/// All inputs have fixed bounds; no provider text, paths, or prompt is retained.
pub fn format(buffer: *[2048]u8, record: *const job.Record) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    if (inputTooLarge(record.phase)) {
        writer.writeAll("Failed: input too large\nStage: Before Codex starts\n") catch unreachable;
        if (record.phase.terminal.pipeline.outcome.failed.input_too_large) |limit| {
            const unit = switch (limit.resource.unit()) {
                .bytes => "bytes",
                .count => "count",
                .unknown => "(unit unknown)",
            };
            writer.print("Resource: {s}\nLimit: {d} {s}", .{ @tagName(limit.resource), limit.allowed, unit }) catch unreachable;
            if (limit.resource.unit() == .bytes and limit.allowed % 1024 == 0)
                writer.print(" ({d} KiB)", .{limit.allowed / 1024}) catch unreachable;
            writer.print("\nObserved{s}: {d} {s}\n", .{
                if (limit.observation == .at_least) " at least" else "",
                limit.observed,
                unit,
            }) catch unreachable;
        } else {
            writer.writeAll("Limit / observation: unknown\n") catch unreachable;
        }
        writer.writeAll("Next: Reduce the review range or Context.\n") catch unreachable;
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
