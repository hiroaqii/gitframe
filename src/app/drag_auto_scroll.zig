//! Root-owned drag-selection auto-scroll policy.
//!
//! This module is deliberately page-neutral. The shell supplies signed pointer
//! samples and a page-owned viewport; pages consume only the resulting bounded
//! semantic step. Timer admission remains an App/runtime concern.

const std = @import("std");

pub const timer_id = "gitframe.drag_auto_scroll";
pub const interval_ns: u64 = 80 * std.time.ns_per_ms;

pub const Target = enum {
    changes,
    compare,
    ai_reviews,
    repository,
};

pub const Direction = enum {
    up,
    down,
};

pub const PointerSample = struct {
    col: i32,
    row: i32,
};

pub const Point = struct {
    col: u16,
    row: u16,
};

pub const Viewport = struct {
    first_col: u16,
    last_col: u16,
    first_row: u16,
    last_row: u16,
};

pub const Intent = struct {
    direction: Direction,
    endpoint: Point,
};

pub const Step = Intent;

pub const StepOutcome = enum {
    moved,
    content_edge,
    stale_owner,
};

pub const Active = struct {
    generation: u64,
    target: Target,
    intent: Intent,
};

pub const State = struct {
    /// Last issued generation. Zero is reserved and never appears in a tick.
    next_generation: u64 = 0,
    generation_exhausted: bool = false,
    active: ?Active = null,
    /// Generation whose repeating timer has been admitted to the runtime
    /// effect queue. It is not changed merely because an intent exists.
    scheduled_generation: ?u64 = null,

    pub fn observe(self: *State, target: Target, pointer: PointerSample, viewport: Viewport) void {
        const intent = classify(pointer, viewport) orelse {
            self.active = null;
            return;
        };

        if (self.active) |*active| {
            if (active.target == target and active.intent.direction == intent.direction) {
                active.intent = intent;
                return;
            }
        }

        const generation = self.mintGeneration() orelse {
            self.active = null;
            return;
        };
        self.active = .{
            .generation = generation,
            .target = target,
            .intent = intent,
        };
    }

    pub fn clear(self: *State) void {
        self.active = null;
    }

    pub fn acceptedTick(self: State, generation: u64) ?Active {
        const active = self.active orelse return null;
        if (active.generation != generation) return null;
        if (self.scheduled_generation != generation) return null;
        return active;
    }

    pub fn complete(self: *State, generation: u64, outcome: StepOutcome) void {
        const active = self.active orelse return;
        if (active.generation != generation) return;
        switch (outcome) {
            .moved => {},
            .content_edge, .stale_owner => self.active = null,
        }
    }

    fn mintGeneration(self: *State) ?u64 {
        if (self.generation_exhausted or self.next_generation == std.math.maxInt(u64)) {
            self.generation_exhausted = true;
            return null;
        }
        self.next_generation += 1;
        if (self.next_generation == std.math.maxInt(u64)) self.generation_exhausted = true;
        return self.next_generation;
    }
};

/// A one-row edge zone lives inside each vertical viewport edge. Pointer rows
/// beyond the viewport keep selecting that edge, while horizontal escape ends
/// the root intent. The endpoint is always safe for page-local hit testing.
pub fn classify(pointer: PointerSample, viewport: Viewport) ?Intent {
    if (viewport.first_col > viewport.last_col or viewport.first_row >= viewport.last_row) return null;
    if (pointer.col < viewport.first_col or pointer.col > viewport.last_col) return null;

    const direction: Direction = if (pointer.row <= viewport.first_row)
        .up
    else if (pointer.row >= viewport.last_row)
        .down
    else
        return null;

    return .{
        .direction = direction,
        .endpoint = .{
            .col = @intCast(pointer.col),
            .row = if (direction == .up) viewport.first_row else viewport.last_row,
        },
    };
}

test "drag auto-scroll classifies only horizontal in-pane edge samples" {
    const viewport: Viewport = .{ .first_col = 12, .last_col = 50, .first_row = 3, .last_row = 18 };
    try std.testing.expectEqual(Intent{ .direction = .up, .endpoint = .{ .col = 20, .row = 3 } }, classify(.{ .col = 20, .row = -5 }, viewport).?);
    try std.testing.expectEqual(Intent{ .direction = .down, .endpoint = .{ .col = 49, .row = 18 } }, classify(.{ .col = 49, .row = 90 }, viewport).?);
    try std.testing.expect(classify(.{ .col = 20, .row = 4 }, viewport) == null);
    try std.testing.expect(classify(.{ .col = 11, .row = 3 }, viewport) == null);
    try std.testing.expect(classify(.{ .col = 20, .row = 3 }, .{ .first_col = 0, .last_col = 20, .first_row = 3, .last_row = 3 }) == null);
}

test "drag auto-scroll keeps one generation at an edge and rejects stale ticks after rearm" {
    const viewport: Viewport = .{ .first_col = 0, .last_col = 30, .first_row = 3, .last_row = 10 };
    var state: State = .{};
    state.observe(.changes, .{ .col = 5, .row = 3 }, viewport);
    const first = state.active.?;
    state.observe(.changes, .{ .col = 7, .row = 1 }, viewport);
    try std.testing.expectEqual(first.generation, state.active.?.generation);
    try std.testing.expectEqual(@as(u16, 7), state.active.?.intent.endpoint.col);

    state.scheduled_generation = first.generation;
    try std.testing.expect(state.acceptedTick(first.generation) != null);
    state.observe(.changes, .{ .col = 7, .row = 6 }, viewport);
    try std.testing.expect(state.active == null);
    state.observe(.ai_reviews, .{ .col = 7, .row = 10 }, viewport);
    try std.testing.expect(state.active.?.generation != first.generation);
    try std.testing.expect(state.acceptedTick(first.generation) == null);
}

test "drag auto-scroll terminal outcomes stop intent while moved retains it" {
    const viewport: Viewport = .{ .first_col = 0, .last_col = 30, .first_row = 3, .last_row = 10 };
    var state: State = .{};
    state.observe(.repository, .{ .col = 5, .row = 10 }, viewport);
    const generation = state.active.?.generation;
    state.complete(generation, .moved);
    try std.testing.expect(state.active != null);
    state.complete(generation, .content_edge);
    try std.testing.expect(state.active == null);
}

test "drag auto-scroll generation exhaustion fails closed after issuing max exactly once" {
    const viewport: Viewport = .{ .first_col = 0, .last_col = 30, .first_row = 3, .last_row = 10 };
    var state: State = .{ .next_generation = std.math.maxInt(u64) - 1 };
    state.observe(.changes, .{ .col = 5, .row = 3 }, viewport);
    try std.testing.expectEqual(std.math.maxInt(u64), state.active.?.generation);
    state.clear();
    state.observe(.changes, .{ .col = 5, .row = 10 }, viewport);
    try std.testing.expect(state.active == null);
}
