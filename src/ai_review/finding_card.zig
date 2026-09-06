//! Projection-only Finding card identity, state, and semantic row plan.
//!
//! Payload text remains owned by the selected Review run. This module knows
//! only exact projection identity and diff-model coordinates.

const std = @import("std");
const committed = @import("../committed_review.zig");
const projection = @import("finding_projection.zig");

pub const header_row: usize = 0;
pub const body_start_row: usize = header_row + 1;
pub const body_rows: usize = 8;
pub const footer_row: usize = body_start_row + body_rows;
pub const collapsed_rows: usize = body_start_row;
pub const expanded_rows: usize = footer_row + 1;
pub const group_spacer_rows: usize = 1;

test "Finding card expanded geometry is one header eight body rows and one footer" {
    try std.testing.expectEqual(@as(usize, 0), header_row);
    try std.testing.expectEqual(@as(usize, 1), body_start_row);
    try std.testing.expectEqual(@as(usize, 8), body_rows);
    try std.testing.expectEqual(@as(usize, 9), footer_row);
    try std.testing.expectEqual(@as(usize, 10), expanded_rows);
}

pub const FindingCardModel = struct {
    identity: projection.Identity,
    entry_index: usize,
    finding_id: []const u8,
    span: projection.ModelSpan,
    side: committed.AnchorSide,
    severity: committed.Severity,

    pub fn init(index: *const projection.FindingProjectionIndex, entry_index: usize) ?FindingCardModel {
        if (entry_index >= index.entries.len) return null;
        const entry = index.entries[entry_index];
        const span = switch (entry.outcome) {
            .mapped => |value| value,
            else => return null,
        };
        return .{
            .identity = index.identity,
            .entry_index = entry_index,
            .finding_id = entry.finding_id,
            .span = span,
            .side = entry.side,
            .severity = entry.severity,
        };
    }
};

pub fn identityEql(left: projection.Identity, right: projection.Identity) bool {
    return left.review_repository_id.eql(right.review_repository_id) and
        left.review_id.eql(right.review_id) and
        left.target.eql(&right.target) and
        left.findings_digest.eql(right.findings_digest);
}

pub const FindingId = struct {
    len: u8 = 0,
    bytes: [committed.limits.max_finding_id_bytes]u8 = [_]u8{0} ** committed.limits.max_finding_id_bytes,

    pub fn init(value: []const u8) ?FindingId {
        if (value.len == 0 or value.len > committed.limits.max_finding_id_bytes) return null;
        var result: FindingId = .{ .len = @intCast(value.len) };
        @memcpy(result.bytes[0..value.len], value);
        return result;
    }

    pub fn slice(self: *const FindingId) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eqlSlice(self: *const FindingId, value: []const u8) bool {
        return std.mem.eql(u8, self.slice(), value);
    }
};

pub const FocusView = union(enum) {
    collapsed,
    expanded: struct { body_scroll: usize = 0 },
};

pub const Focused = struct {
    identity: projection.Identity,
    finding_id: FindingId,
    view: FocusView = .collapsed,
};

pub const Scroll = struct {
    direction: enum { up, down },
    max_scroll: usize,
};

pub const Command = union(enum) {
    focus: FindingCardModel,
    cycle: FindingCardModel,
    toggle,
    scroll: Scroll,
    copy,
    leave,
};

pub const Action = enum {
    none,
    ensure_visible,
    copy_requested,
};

pub const State = union(enum) {
    unfocused,
    focused: Focused,

    pub fn isFocused(self: State) bool {
        return self == .focused;
    }

    pub fn focusedValue(self: *const State) ?*const Focused {
        return switch (self.*) {
            .focused => |*value| value,
            .unfocused => null,
        };
    }

    pub fn matches(self: State, model: FindingCardModel) bool {
        return switch (self) {
            .unfocused => false,
            .focused => |focused| identityEql(focused.identity, model.identity) and
                focused.finding_id.eqlSlice(model.finding_id),
        };
    }

    pub fn expanded(self: State, model: FindingCardModel) bool {
        if (!self.matches(model)) return false;
        return switch (self.focused.view) {
            .collapsed => false,
            .expanded => true,
        };
    }

    pub fn bodyScroll(self: State, model: FindingCardModel) usize {
        if (!self.matches(model)) return 0;
        return switch (self.focused.view) {
            .collapsed => 0,
            .expanded => |expanded_value| expanded_value.body_scroll,
        };
    }

    pub fn cardRows(self: State, model: FindingCardModel) usize {
        return if (self.expanded(model)) expanded_rows else collapsed_rows;
    }

    pub fn apply(self: *State, command: Command) Action {
        return switch (command) {
            .focus, .cycle => |model| result: {
                const finding_id = FindingId.init(model.finding_id) orelse {
                    self.* = .unfocused;
                    break :result .none;
                };
                self.* = .{ .focused = .{
                    .identity = model.identity,
                    .finding_id = finding_id,
                } };
                break :result .ensure_visible;
            },
            .toggle => result: {
                switch (self.*) {
                    .unfocused => break :result .none,
                    .focused => |*focused| switch (focused.view) {
                        .collapsed => focused.view = .{ .expanded = .{} },
                        .expanded => focused.view = .collapsed,
                    },
                }
                break :result .ensure_visible;
            },
            .scroll => |scroll| result: {
                switch (self.*) {
                    .unfocused => break :result .none,
                    .focused => |*focused| switch (focused.view) {
                        .collapsed => break :result .none,
                        .expanded => |*expanded_value| {
                            const current = @min(expanded_value.body_scroll, scroll.max_scroll);
                            expanded_value.body_scroll = switch (scroll.direction) {
                                .up => current -| 1,
                                .down => @min(current +| 1, scroll.max_scroll),
                            };
                        },
                    },
                }
                break :result .none;
            },
            .copy => if (self.isFocused()) .copy_requested else .none,
            .leave => result: {
                self.* = .unfocused;
                break :result .none;
            },
        };
    }

    /// Preserve state only for the exact projection identity and a still
    /// mapped Finding. This is used solely at accepted owner replacement.
    pub fn transferred(self: State, index: *const projection.FindingProjectionIndex) State {
        const focused = switch (self) {
            .unfocused => return .unfocused,
            .focused => |value| value,
        };
        if (!identityEql(focused.identity, index.identity)) return .unfocused;
        for (index.entries) |entry| {
            if (!focused.finding_id.eqlSlice(entry.finding_id)) continue;
            return switch (entry.outcome) {
                .mapped => self,
                else => .unfocused,
            };
        }
        return .unfocused;
    }

    pub fn reconcileVisible(self: *State, models: []const FindingCardModel) bool {
        if (!self.isFocused()) return false;
        for (models) |model| if (self.matches(model)) return false;
        self.* = .unfocused;
        return true;
    }
};

pub const Group = struct {
    hunk_ordinal: usize,
    last_diff_line_ordinal: usize,
    card_start: usize,
    card_count: usize,
};

pub const RowPlan = struct {
    groups: []Group,
    cards: []FindingCardModel,

    pub fn build(
        allocator: std.mem.Allocator,
        models: []const FindingCardModel,
        folded_hunks: []const bool,
    ) std.mem.Allocator.Error!RowPlan {
        var groups_list: std.ArrayList(Group) = .empty;
        defer groups_list.deinit(allocator);

        for (models) |model| {
            if (model.span.hunk_ordinal < folded_hunks.len and folded_hunks[model.span.hunk_ordinal]) continue;
            var insertion = groups_list.items.len;
            for (groups_list.items, 0..) |group, index| {
                if (sameOrigin(group, model.span)) {
                    insertion = index;
                    break;
                }
                if (originBefore(model.span, group)) {
                    try groups_list.insert(allocator, index, .{
                        .hunk_ordinal = model.span.hunk_ordinal,
                        .last_diff_line_ordinal = model.span.last_diff_line_ordinal,
                        .card_start = 0,
                        .card_count = 0,
                    });
                    insertion = index;
                    break;
                }
            }
            if (insertion == groups_list.items.len) {
                try groups_list.append(allocator, .{
                    .hunk_ordinal = model.span.hunk_ordinal,
                    .last_diff_line_ordinal = model.span.last_diff_line_ordinal,
                    .card_start = 0,
                    .card_count = 0,
                });
            }
        }

        for (models) |model| {
            if (model.span.hunk_ordinal < folded_hunks.len and folded_hunks[model.span.hunk_ordinal]) continue;
            for (groups_list.items) |*group| {
                if (sameOrigin(group.*, model.span)) {
                    group.card_count += 1;
                    break;
                }
            }
        }

        var total_cards: usize = 0;
        for (groups_list.items) |*group| {
            group.card_start = total_cards;
            total_cards += group.card_count;
        }
        const cards = try allocator.alloc(FindingCardModel, total_cards);
        errdefer allocator.free(cards);
        const cursors = try allocator.alloc(usize, groups_list.items.len);
        defer allocator.free(cursors);
        @memset(cursors, 0);
        for (models) |model| {
            if (model.span.hunk_ordinal < folded_hunks.len and folded_hunks[model.span.hunk_ordinal]) continue;
            for (groups_list.items, 0..) |group, group_index| {
                if (!sameOrigin(group, model.span)) continue;
                cards[group.card_start + cursors[group_index]] = model;
                cursors[group_index] += 1;
                break;
            }
        }

        return .{
            .groups = try groups_list.toOwnedSlice(allocator),
            .cards = cards,
        };
    }

    /// Build a borrowing plan in caller-owned storage. The caller proves all
    /// capacities before an enclosing state transition begins.
    pub fn buildPrepared(
        models: []const FindingCardModel,
        folded_hunks: []const bool,
        groups_storage: []Group,
        cards_storage: []FindingCardModel,
        cursors_storage: []usize,
    ) RowPlan {
        std.debug.assert(groups_storage.len >= models.len);
        std.debug.assert(cards_storage.len >= models.len);
        std.debug.assert(cursors_storage.len >= models.len);

        var group_count: usize = 0;
        for (models) |model| {
            if (model.span.hunk_ordinal < folded_hunks.len and folded_hunks[model.span.hunk_ordinal]) continue;
            var insertion = group_count;
            var found = false;
            for (groups_storage[0..group_count], 0..) |group, index| {
                if (sameOrigin(group, model.span)) {
                    found = true;
                    break;
                }
                if (originBefore(model.span, group)) {
                    insertion = index;
                    break;
                }
            }
            if (found) continue;
            std.mem.copyBackwards(
                Group,
                groups_storage[insertion + 1 .. group_count + 1],
                groups_storage[insertion..group_count],
            );
            groups_storage[insertion] = .{
                .hunk_ordinal = model.span.hunk_ordinal,
                .last_diff_line_ordinal = model.span.last_diff_line_ordinal,
                .card_start = 0,
                .card_count = 0,
            };
            group_count += 1;
        }

        const groups = groups_storage[0..group_count];
        for (models) |model| {
            if (model.span.hunk_ordinal < folded_hunks.len and folded_hunks[model.span.hunk_ordinal]) continue;
            for (groups) |*group| {
                if (sameOrigin(group.*, model.span)) {
                    group.card_count += 1;
                    break;
                }
            }
        }
        var total_cards: usize = 0;
        for (groups) |*group| {
            group.card_start = total_cards;
            total_cards += group.card_count;
        }
        const cursors = cursors_storage[0..group_count];
        @memset(cursors, 0);
        for (models) |model| {
            if (model.span.hunk_ordinal < folded_hunks.len and folded_hunks[model.span.hunk_ordinal]) continue;
            for (groups, 0..) |group, group_index| {
                if (!sameOrigin(group, model.span)) continue;
                cards_storage[group.card_start + cursors[group_index]] = model;
                cursors[group_index] += 1;
                break;
            }
        }
        return .{ .groups = groups, .cards = cards_storage[0..total_cards] };
    }

    pub fn deinit(self: *RowPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.cards);
        allocator.free(self.groups);
        self.* = undefined;
    }

    pub fn cardsForGroup(self: RowPlan, group: Group) []const FindingCardModel {
        return self.cards[group.card_start .. group.card_start + group.card_count];
    }

    pub fn groupAtOrigin(self: RowPlan, hunk_ordinal: usize, last_diff_line_ordinal: usize) ?Group {
        for (self.groups) |group| {
            if (group.hunk_ordinal == hunk_ordinal and group.last_diff_line_ordinal == last_diff_line_ordinal) return group;
        }
        return null;
    }

    pub fn cardIndex(self: RowPlan, model: FindingCardModel) ?usize {
        for (self.cards, 0..) |candidate, index| {
            if (candidate.entry_index == model.entry_index and identityEql(candidate.identity, model.identity)) return index;
        }
        return null;
    }
};

fn sameOrigin(group: Group, span: projection.ModelSpan) bool {
    return group.hunk_ordinal == span.hunk_ordinal and
        group.last_diff_line_ordinal == span.last_diff_line_ordinal;
}

fn originBefore(span: projection.ModelSpan, group: Group) bool {
    return span.hunk_ordinal < group.hunk_ordinal or
        (span.hunk_ordinal == group.hunk_ordinal and span.last_diff_line_ordinal < group.last_diff_line_ordinal);
}

fn testIdentity(seed: u8) projection.Identity {
    var repository_id: committed.ReviewRepositoryId = .{ .bytes = [_]u8{0} ** 16 };
    var review_id: committed.ReviewId = .{ .bytes = [_]u8{0} ** 16 };
    var digest: committed.Sha256Digest = .{ .bytes = [_]u8{0} ** 32 };
    repository_id.bytes[0] = seed;
    review_id.bytes[0] = seed;
    digest.bytes[0] = seed;
    return .{
        .review_repository_id = repository_id,
        .review_id = review_id,
        .target = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = .{},
            .head_oid = .{},
            .diff_base_oid = .{},
        },
        .findings_digest = digest,
    };
}

fn testModel(identity: projection.Identity, entry_index: usize, id: []const u8, hunk: usize, line: usize) FindingCardModel {
    return .{
        .identity = identity,
        .entry_index = entry_index,
        .finding_id = id,
        .span = .{
            .file_ordinal = 0,
            .hunk_ordinal = hunk,
            .first_diff_line_ordinal = line,
            .last_diff_line_ordinal = line,
        },
        .side = .after,
        .severity = .warning,
    };
}

test "Finding card state is closed and exact-identity bound" {
    const identity = testIdentity(1);
    const first = testModel(identity, 0, "F-1", 0, 2);
    const second = testModel(identity, 1, "F-2", 0, 2);
    var state: State = .unfocused;
    try std.testing.expectEqual(Action.ensure_visible, state.apply(.{ .focus = first }));
    try std.testing.expect(state.matches(first));
    _ = state.apply(.toggle);
    try std.testing.expect(state.expanded(first));
    _ = state.apply(.{ .scroll = .{ .direction = .down, .max_scroll = 3 } });
    try std.testing.expectEqual(@as(usize, 1), state.bodyScroll(first));
    _ = state.apply(.{ .cycle = second });
    try std.testing.expect(state.matches(second));
    try std.testing.expect(!state.expanded(second));
    const different = testModel(testIdentity(2), 0, "F-2", 0, 2);
    try std.testing.expect(!state.matches(different));
    _ = state.apply(.leave);
    try std.testing.expect(!state.isFocused());
}

test "Finding card scroll clamps stale resize state before moving" {
    const model = testModel(testIdentity(3), 0, "F-resize", 0, 1);
    var state: State = .unfocused;
    _ = state.apply(.{ .focus = model });
    _ = state.apply(.toggle);
    state.focused.view.expanded.body_scroll = 9;

    _ = state.apply(.{ .scroll = .{ .direction = .up, .max_scroll = 2 } });
    try std.testing.expectEqual(@as(usize, 1), state.bodyScroll(model));

    state.focused.view.expanded.body_scroll = 9;
    _ = state.apply(.{ .scroll = .{ .direction = .down, .max_scroll = 2 } });
    try std.testing.expectEqual(@as(usize, 2), state.bodyScroll(model));
}

test "Finding card presentation row plan preserves card order and omits folded hunks" {
    const identity = testIdentity(1);
    const models = [_]FindingCardModel{
        testModel(identity, 0, "later", 1, 4),
        testModel(identity, 1, "first-a", 0, 2),
        testModel(identity, 2, "first-b", 0, 2),
    };
    var plan = try RowPlan.build(std.testing.allocator, &models, &.{ false, false });
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), plan.groups.len);
    try std.testing.expectEqualStrings("first-a", plan.cardsForGroup(plan.groups[0])[0].finding_id);
    try std.testing.expectEqualStrings("first-b", plan.cardsForGroup(plan.groups[0])[1].finding_id);

    var folded = try RowPlan.build(std.testing.allocator, &models, &.{ false, true });
    defer folded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), folded.groups.len);
    try std.testing.expectEqual(@as(usize, 2), folded.cards.len);
}

test "Finding card row plan reports allocation failure" {
    const identity = testIdentity(4);
    const models = [_]FindingCardModel{testModel(identity, 0, "oom", 0, 1)};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, RowPlan.build(failing.allocator(), &models, &.{false}));
}

test "Finding card reload transfer preserves only an exact still-mapped owner" {
    const identity = testIdentity(5);
    const model = testModel(identity, 0, "reload", 0, 1);
    var state: State = .unfocused;
    _ = state.apply(.{ .focus = model });
    _ = state.apply(.toggle);
    var entries = [_]projection.Entry{.{
        .finding_id = @constCast("reload"),
        .severity = .warning,
        .anchor_path_bytes = @constCast("a"),
        .side = .after,
        .start_line = 1,
        .end_line = 1,
        .content_digest = .{ .bytes = [_]u8{0} ** 32 },
        .file_ordinal = 0,
        .outcome = .{ .mapped = model.span },
    }};
    var files: [0]projection.FileRecord = .{};
    var mapped_indices = [_]usize{0};
    var index: projection.FindingProjectionIndex = .{
        .identity = identity,
        .files = &files,
        .entries = &entries,
        .summary = .{ .total = 1, .mapped = 1, .warning = 1 },
        .mapped_entry_indices = &mapped_indices,
    };
    try std.testing.expect(state.transferred(&index).expanded(model));

    index.entries[0].outcome = .{ .stale = .range_out_of_bounds };
    try std.testing.expect(!state.transferred(&index).isFocused());
    index.entries[0].outcome = .{ .mapped = model.span };
    index.identity = testIdentity(6);
    try std.testing.expect(!state.transferred(&index).isFocused());
}

test "Finding card shared model has no decoded payload fields" {
    try std.testing.expect(!@hasField(FindingCardModel, "body"));
    try std.testing.expect(!@hasField(FindingCardModel, "suggestion"));
    try std.testing.expect(!@hasField(FindingCardModel, "findings_bytes"));
    try std.testing.expect(!@hasField(FindingCardModel, "finding_set"));
}
