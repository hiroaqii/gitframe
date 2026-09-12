//! Provider-neutral retained state for one hosted AI review job.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const root_capability = @import("../repo/root_capability.zig");
const pipeline = @import("runner.zig");

pub const Id = u32;
pub const Generation = u64;

pub const Key = struct {
    id: Id,
    generation: Generation,

    pub fn eql(self: Key, other: Key) bool {
        return self.id == other.id and self.generation == other.generation;
    }
};

/// Identity retained independently of the currently selected repository.
pub const Scope = struct {
    repository: root_capability.Identity,
    target: committed_review.CommittedReviewTarget,

    pub fn eql(self: *const Scope, other: *const Scope) bool {
        return self.repository.eql(other.repository) and self.target.eql(&other.target);
    }
};

pub const StartFailure = enum {
    review_task_start_failed,
    publication_task_start_failed,
};

/// Pipeline terminals already own the complete provider/publication result.
/// Task-start failures are job orchestration failures and stay outside that
/// domain vocabulary.
pub const Terminal = union(enum) {
    pipeline: pipeline.Terminal,
    start_failed: StartFailure,

    pub fn canceled() Terminal {
        return .{ .pipeline = .{ .outcome = .canceled } };
    }
};

pub const Phase = union(enum) {
    queued,
    reviewing,
    publishing,
    terminal: Terminal,
};

pub const Record = struct {
    key: Key,
    sequence: u64,
    terminal_sequence: ?u64 = null,
    scope: Scope,
    display: @import("diagnostic.zig").Display = .{},
    phase: Phase = .queued,
    request: ?pipeline.Request,
    canceled_generation: std.atomic.Value(u64) = .init(0),
    cancel_latched: bool = false,
    unread: bool = false,

    pub fn init(key: Key, sequence: u64, scope: Scope, request: pipeline.Request) Record {
        return .{
            .key = key,
            .sequence = sequence,
            .scope = scope,
            .display = request.displaySnapshot(),
            .request = request,
        };
    }

    pub fn deinit(self: *Record) void {
        if (self.request) |*request| request.deinit();
        self.* = undefined;
    }

    pub fn requestCancel(self: *Record) void {
        self.cancel_latched = true;
        if (self.phase == .reviewing) {
            self.canceled_generation.store(self.key.generation, .release);
        }
    }

    pub fn cancellation(self: *const Record) @import("../process/runner.zig").CancellationView {
        return .{
            .canceled_generation = &self.canceled_generation,
            .generation = self.key.generation,
        };
    }
};
