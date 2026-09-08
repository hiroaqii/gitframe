//! Chasen task bridge for the bounded hosted AI review job owner.

const std = @import("std");
const chasen = @import("chasen");
const job = @import("../ai_review/job.zig");
const job_owner = @import("../ai_review/job_owner.zig");
const pipeline = @import("../ai_review/runner.zig");

pub const ReviewTaskOutcome = union(enum) {
    pipeline: pipeline.ReviewResult,
    start_failed,

    fn deinit(self: *ReviewTaskOutcome) void {
        switch (self.*) {
            .pipeline => |*result| result.deinit(),
            .start_failed => {},
        }
        self.* = .start_failed;
    }
};

pub const PublicationTaskOutcome = union(enum) {
    terminal: pipeline.Terminal,
    start_failed,
};

pub const Msg = union(enum) {
    review_finished: struct {
        key: job.Key,
        outcome: ReviewTaskOutcome,
    },
    publication_finished: struct {
        key: job.Key,
        outcome: PublicationTaskOutcome,
    },

    pub fn deinit(self: *Msg) void {
        switch (self.*) {
            .review_finished => |*finished| finished.outcome.deinit(),
            .publication_finished => {},
        }
        self.* = undefined;
    }
};

pub const PumpOutcome = struct {
    started: bool = false,
    start_failures: usize = 0,
};

pub const UpdateOutcome = struct {
    adopted: bool = false,
    became_publishing: bool = false,
    became_terminal: bool = false,
    start_failure: bool = false,
};

/// Starts at most one review task. Immediate failures are terminalized and
/// the next queued job is attempted, so a bad allocation/queue slot cannot
/// wedge the bounded FIFO.
pub fn pump(
    comptime RootMsg: type,
    owner: *job_owner.Owner,
    ctx: *chasen.Ctx(RootMsg),
) PumpOutcome {
    var outcome: PumpOutcome = .{};
    while (owner.takeNextReview()) |start| {
        var owned_start = start;
        var request_owned = true;
        defer if (request_owned) owned_start.request.deinit();

        const task = ctx.allocator().create(ReviewTask(RootMsg)) catch {
            _ = owner.reviewTaskStartFailed(start.key);
            outcome.start_failures += 1;
            continue;
        };
        task.* = .{
            .key = start.key,
            .request = start.request,
            .cancellation = start.cancellation,
        };
        request_owned = false;
        ctx.task().spawnWith(.{
            .ctx = task,
            .run = ReviewTask(RootMsg).run,
            .failed = ReviewTask(RootMsg).failed,
        }) catch {
            task.request.deinit();
            ctx.allocator().destroy(task);
            _ = owner.reviewTaskStartFailed(start.key);
            outcome.start_failures += 1;
            continue;
        };
        outcome.started = true;
        break;
    }
    return outcome;
}

/// Owns a delivered task message until it is either moved into the next task
/// or disposed. This function is intentionally infallible: allocation and
/// queue failures are job terminals, not App.update error exits.
pub fn update(
    comptime RootMsg: type,
    owner: *job_owner.Owner,
    delivered: Msg,
    ctx: *chasen.Ctx(RootMsg),
) UpdateOutcome {
    var message = delivered;
    defer message.deinit();
    var result: UpdateOutcome = .{};

    switch (message) {
        .review_finished => |*finished| switch (finished.outcome) {
            .start_failed => {
                result.adopted = owner.reviewTaskStartFailed(finished.key);
                result.became_terminal = result.adopted;
                result.start_failure = result.adopted;
            },
            .pipeline => |*review_result| switch (review_result.*) {
                .terminal => |terminal| {
                    result.adopted = owner.finishReview(finished.key, terminal);
                    result.became_terminal = result.adopted;
                },
                .ready => {
                    switch (owner.readyDisposition(finished.key)) {
                        .stale => return result,
                        .canceled => {
                            result.adopted = owner.cancelReady(finished.key);
                            result.became_terminal = result.adopted;
                            return result;
                        },
                        .accept => {},
                    }

                    var ready = review_result.ready;
                    review_result.* = .{ .terminal = .{ .outcome = .canceled } };
                    var ready_owned = true;
                    defer if (ready_owned) ready.deinit();

                    const publication_task = ctx.allocator().create(PublicationTask(RootMsg)) catch {
                        _ = owner.publicationTaskStartFailedAfterReview(finished.key);
                        result.adopted = true;
                        result.became_terminal = true;
                        result.start_failure = true;
                        return result;
                    };
                    publication_task.* = .{ .key = finished.key, .ready = ready };
                    ready_owned = false;

                    if (!owner.beginPublishing(finished.key)) {
                        publication_task.ready.deinit();
                        ctx.allocator().destroy(publication_task);
                        _ = owner.cancelReady(finished.key);
                        result.adopted = true;
                        result.became_terminal = true;
                        return result;
                    }
                    result.adopted = true;
                    result.became_publishing = true;
                    ctx.task().spawnWith(.{
                        .ctx = publication_task,
                        .run = PublicationTask(RootMsg).run,
                        .failed = PublicationTask(RootMsg).failed,
                    }) catch {
                        publication_task.ready.deinit();
                        ctx.allocator().destroy(publication_task);
                        _ = owner.publicationTaskStartFailed(finished.key);
                        result.became_publishing = false;
                        result.became_terminal = true;
                        result.start_failure = true;
                    };
                },
            },
        },
        .publication_finished => |finished| switch (finished.outcome) {
            .terminal => |terminal| {
                result.adopted = owner.finishPublication(finished.key, terminal);
                result.became_terminal = result.adopted;
            },
            .start_failed => {
                result.adopted = owner.publicationTaskStartFailed(finished.key);
                result.became_terminal = result.adopted;
                result.start_failure = result.adopted;
            },
        },
    }
    return result;
}

fn ReviewTask(comptime RootMsg: type) type {
    return struct {
        key: job.Key,
        request: pipeline.Request,
        cancellation: @import("../process/runner.zig").CancellationView,

        fn run(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) RootMsg {
            const self: *@This() = @ptrCast(@alignCast(context));
            const key = self.key;
            const request = self.request;
            const cancellation = self.cancellation;
            allocator.destroy(self);
            return RootMsg.aiReviewJob(.{ .review_finished = .{
                .key = key,
                .outcome = .{ .pipeline = pipeline.review(allocator, io, request, .{
                    .cancellation = cancellation,
                }) },
            } });
        }

        fn failed(context: *anyopaque, _: chasen.TaskFailure, allocator: std.mem.Allocator) RootMsg {
            const self: *@This() = @ptrCast(@alignCast(context));
            const key = self.key;
            self.request.deinit();
            allocator.destroy(self);
            return RootMsg.aiReviewJob(.{ .review_finished = .{
                .key = key,
                .outcome = .start_failed,
            } });
        }
    };
}

fn PublicationTask(comptime RootMsg: type) type {
    return struct {
        key: job.Key,
        ready: pipeline.ReadyToPublish,

        fn run(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) RootMsg {
            const self: *@This() = @ptrCast(@alignCast(context));
            const key = self.key;
            const ready = self.ready;
            allocator.destroy(self);
            return RootMsg.aiReviewJob(.{ .publication_finished = .{
                .key = key,
                .outcome = .{ .terminal = pipeline.publishReady(allocator, io, ready) },
            } });
        }

        fn failed(context: *anyopaque, _: chasen.TaskFailure, allocator: std.mem.Allocator) RootMsg {
            const self: *@This() = @ptrCast(@alignCast(context));
            const key = self.key;
            self.ready.deinit();
            allocator.destroy(self);
            return RootMsg.aiReviewJob(.{ .publication_finished = .{
                .key = key,
                .outcome = .start_failed,
            } });
        }
    };
}
