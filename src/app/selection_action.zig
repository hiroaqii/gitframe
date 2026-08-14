//! Responsibility-neutral retained-selection action presentation.
//!
//! Pages keep content identity, selected bytes, ranges, and lifecycle
//! authority. This module owns only the shared Copy/Clear action vocabulary,
//! exact two-row presentation, clipped hit geometry, virtual-row projection,
//! dispatch terminals, and allocation-free viewport arithmetic.

const std = @import("std");
const chasen = @import("chasen");
const draw = @import("draw");

pub const Action = enum {
    copy,
    clear,
};

pub const virtual_row_count: usize = 2;
pub const controls_text = "[y Copy] [Esc Clear]";

pub fn keyToAction(key: chasen.Key) ?Action {
    if (key.matches(chasen.Key.escape, .{})) return .clear;
    if (key.matches('y', .{})) return .copy;
    return null;
}

pub const CopyError = error{
    AuthorityInvalid,
    OutOfMemory,
};

/// Responsibility-neutral dispatch terminal. The returned copy slice is owned
/// by the caller; every other terminal carries no storage.
pub const DispatchTerminal = union(enum) {
    none,
    copy: []u8,
    cleared,
    authority_invalid,
    preparation_failed,
};

/// Adapter contract:
/// - `available() bool` reports whether a retained owner exists at all;
/// - `copy(allocator) CopyError![]u8` performs page-specific re-admission and
///   duplicates its already-frozen bytes;
/// - `clear(allocator) void` owns page-specific viewport capture/restore.
///
/// Authority failure clears through the same adapter before returning, while
/// allocation failure deliberately preserves the retained owner.
pub fn dispatch(
    allocator: std.mem.Allocator,
    action: Action,
    adapter: anytype,
) DispatchTerminal {
    if (!adapter.available()) return .none;
    return switch (action) {
        .clear => blk: {
            adapter.clear(allocator);
            break :blk .cleared;
        },
        .copy => .{ .copy = adapter.copy(allocator) catch |err| switch (err) {
            error.AuthorityInvalid => {
                adapter.clear(allocator);
                return .authority_invalid;
            },
            error.OutOfMemory => return .preparation_failed,
        } },
    };
}

pub const ActionRow = enum(u1) {
    summary = 0,
    controls = 1,
};

pub const Location = union(enum) {
    source: usize,
    action: ActionRow,
};

pub const Bias = enum {
    before,
    after,
};

pub const Projection = struct {
    source_rows: usize,
    after_source_row: usize,

    pub fn init(source_rows: usize, after_source_row: usize) ?Projection {
        if (source_rows == 0 or after_source_row >= source_rows) return null;
        return .{ .source_rows = source_rows, .after_source_row = after_source_row };
    }

    pub fn insertionOffset(self: Projection) usize {
        return self.after_source_row + 1;
    }

    pub fn presentationRows(self: Projection) usize {
        return self.source_rows +| virtual_row_count;
    }

    pub fn sourceToPresentation(self: Projection, source_row: usize) ?usize {
        if (source_row >= self.source_rows) return null;
        return source_row +| if (source_row > self.after_source_row) virtual_row_count else 0;
    }

    pub fn locate(self: Projection, presentation_row: usize) ?Location {
        if (presentation_row >= self.presentationRows()) return null;
        const insertion = self.insertionOffset();
        if (presentation_row < insertion) return .{ .source = presentation_row };
        if (presentation_row < insertion +| virtual_row_count) {
            return .{ .action = @enumFromInt(presentation_row - insertion) };
        }
        return .{ .source = presentation_row - virtual_row_count };
    }

    /// Resolve a virtual ordinal to an adjacent real source row. Cursor,
    /// search, and selection code never receives an action-row coordinate.
    pub fn nearestSource(self: Projection, presentation_row: usize, bias: Bias) ?usize {
        const location = self.locate(@min(presentation_row, self.presentationRows() - 1)) orelse return null;
        return switch (location) {
            .source => |source| source,
            .action => switch (bias) {
                .before => self.after_source_row,
                .after => if (self.after_source_row + 1 < self.source_rows)
                    self.after_source_row + 1
                else
                    self.after_source_row,
            },
        };
    }

    pub fn sourceAtOrAfter(self: Projection, presentation_row: usize) usize {
        const insertion = self.insertionOffset();
        if (presentation_row < insertion) return @min(presentation_row, self.source_rows);
        if (presentation_row < insertion +| virtual_row_count) return @min(insertion, self.source_rows);
        return @min(presentation_row - virtual_row_count, self.source_rows);
    }

    pub fn actionPresentationRow(self: Projection, action_row: ActionRow) usize {
        return self.insertionOffset() +| @intFromEnum(action_row);
    }

    pub fn maxScroll(self: Projection, visible_rows: usize) usize {
        return self.presentationRows() -| visible_rows;
    }

    pub fn clampScroll(self: Projection, scroll: usize, visible_rows: usize) usize {
        return @min(scroll, self.maxScroll(visible_rows));
    }

    /// Scroll just enough to reveal the selected source tail and both action
    /// rows. Tiny and zero-height viewports saturate without inventing rows.
    pub fn reveal(self: Projection, current_scroll: usize, visible_rows: usize) usize {
        if (visible_rows == 0) return self.clampScroll(current_scroll, visible_rows);
        const last = self.actionPresentationRow(.controls);
        var scroll = self.clampScroll(current_scroll, visible_rows);
        if (self.after_source_row < scroll) scroll = self.after_source_row;
        if (last >= scroll + visible_rows) scroll = last + 1 - visible_rows;
        return self.clampScroll(scroll, visible_rows);
    }

    pub fn actionScreenRow(self: Projection, action: ActionRow, scroll: usize, visible_rows: usize) ?usize {
        const presentation = self.actionPresentationRow(action);
        if (presentation < scroll or presentation >= scroll +| visible_rows) return null;
        return presentation - scroll;
    }
};

pub const Region = struct {
    col: u16,
    width: u16,

    pub fn contains(self: Region, col: u16) bool {
        return col >= self.col and col < self.col +| self.width;
    }
};

pub const Layout = struct {
    region: Region,
    copy: ?Region,
    clear: ?Region,

    pub fn targetAt(self: Layout, col: u16, row: ActionRow) ?Action {
        if (row != .controls) return null;
        if (self.copy) |region| if (region.contains(col)) return .copy;
        if (self.clear) |region| if (region.contains(col)) return .clear;
        return null;
    }
};

/// Complete targets only are interactive. A clipped or hidden label has no
/// hit range, while keyboard actions remain available through page admission.
pub fn actionLayout(region: Region) Layout {
    const copy_width: u16 = 8;
    const clear_width: u16 = 11;
    const copy_col = region.col;
    const clear_col = copy_col +| copy_width +| 1;
    const end = region.col +| region.width;
    return .{
        .region = region,
        .copy = if (copy_col +| copy_width <= end) .{ .col = copy_col, .width = copy_width } else null,
        .clear = if (clear_col +| clear_width <= end) .{ .col = clear_col, .width = clear_width } else null,
    };
}

/// Draw exactly one action row in a page-selected rectangle. The page owns
/// surrounding chrome and supplies the already-composed action style.
pub fn drawActionRow(
    surface: *chasen.Surface,
    row: u16,
    layout: Layout,
    action_row: ActionRow,
    line_count: usize,
    style: chasen.TextStyle,
) !void {
    if (row >= surface.size().height or layout.region.width == 0 or layout.region.col >= surface.size().width) return;
    const width = @min(layout.region.width, surface.size().width - layout.region.col);
    surface.fill(.{
        .col = layout.region.col,
        .row = row,
        .width = width,
        .height = 1,
    }, .{ .style = style });
    var action_surface = surface.child(.{
        .col = layout.region.col,
        .row = row,
        .width = width,
        .height = 1,
    });
    const text = switch (action_row) {
        .summary => try std.fmt.allocPrint(surface.frameAllocator(), "{d} lines selected", .{line_count}),
        .controls => controls_text,
    };
    try draw.copyClippedTextAt(&action_surface, 0, 0, text, style);
}

/// Scalar identity of one source/presentation mapping. `mapping_variant` is
/// an opaque page-provided discriminator (for example a diff display mode);
/// this module never interprets it.
pub const ProjectionBasis = struct {
    layout_revision: u64,
    mapping_variant: u8 = 0,
    source_rows: usize,
    action_insertion_offset: ?usize,

    pub fn eql(self: ProjectionBasis, other: ProjectionBasis) bool {
        return std.meta.eql(self, other);
    }

    pub fn presentationRows(self: ProjectionBasis) usize {
        return self.source_rows +| if (self.action_insertion_offset != null) virtual_row_count else 0;
    }

    pub fn maxScroll(self: ProjectionBasis, visible_rows: usize) usize {
        return self.presentationRows() -| visible_rows;
    }

    pub fn clampScroll(self: ProjectionBasis, scroll: usize, visible_rows: usize) usize {
        return @min(scroll, self.maxScroll(visible_rows));
    }
};

pub const AnchorPosition = struct {
    source_offset_fallback: usize,
    signed_screen_delta: isize,
};

pub fn ViewportAnchor(comptime SemanticSource: type) type {
    return struct {
        semantic_source: SemanticSource,
        source_offset_fallback: usize,
        signed_screen_delta: isize,
        raw_presentation_scroll: usize,
        basis: ProjectionBasis,
    };
}

pub fn captureAnchorPosition(
    source_rows: usize,
    projection: ?Projection,
    presentation_scroll: usize,
) AnchorPosition {
    if (source_rows == 0) return .{ .source_offset_fallback = 0, .signed_screen_delta = 0 };
    const active = projection orelse return .{
        .source_offset_fallback = @min(presentation_scroll, source_rows - 1),
        .signed_screen_delta = 0,
    };
    const clamped = @min(presentation_scroll, active.presentationRows() - 1);
    return switch (active.locate(clamped).?) {
        .source => |source| .{ .source_offset_fallback = source, .signed_screen_delta = 0 },
        .action => {
            const next_source = active.after_source_row + 1;
            if (next_source < active.source_rows) {
                const presentation = active.sourceToPresentation(next_source).?;
                return .{
                    .source_offset_fallback = next_source,
                    .signed_screen_delta = @intCast(presentation - clamped),
                };
            }
            const tail_presentation = active.sourceToPresentation(active.after_source_row).?;
            return .{
                .source_offset_fallback = active.after_source_row,
                .signed_screen_delta = -@as(isize, @intCast(clamped - tail_presentation)),
            };
        },
    };
}

pub fn restoreViewportAnchor(
    anchor: anytype,
    incoming_basis: ProjectionBasis,
    incoming_projection: ?Projection,
    resolved_semantic_source: ?usize,
    visible_rows: usize,
) usize {
    if (incoming_basis.source_rows == 0) return 0;
    if (anchor.basis.eql(incoming_basis)) {
        return incoming_basis.clampScroll(anchor.raw_presentation_scroll, visible_rows);
    }

    const source = @min(
        resolved_semantic_source orelse anchor.source_offset_fallback,
        incoming_basis.source_rows - 1,
    );
    const presentation = if (incoming_projection) |projection|
        projection.sourceToPresentation(source) orelse source
    else
        source;
    const raw: usize = if (anchor.signed_screen_delta >= 0)
        presentation -| @as(usize, @intCast(anchor.signed_screen_delta))
    else
        presentation +| @as(usize, @intCast(-anchor.signed_screen_delta));
    return incoming_basis.clampScroll(raw, visible_rows);
}

test "selection action maps exact keys without command modifiers" {
    try std.testing.expectEqual(Action.copy, keyToAction(.{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(Action.clear, keyToAction(.{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expect(keyToAction(.{ .codepoint = 'y', .mods = .{ .ctrl = true } }) == null);
}

test "selection action dispatch separates authority allocation and clear terminals" {
    const Adapter = struct {
        present: bool = true,
        valid: bool = true,
        fail_allocation: bool = false,
        cleared: bool = false,

        pub fn available(self: *@This()) bool {
            return self.present;
        }

        pub fn copy(self: *@This(), allocator: std.mem.Allocator) CopyError![]u8 {
            if (!self.valid) return error.AuthorityInvalid;
            if (self.fail_allocation) return error.OutOfMemory;
            return allocator.dupe(u8, "frozen");
        }

        pub fn clear(self: *@This(), _: std.mem.Allocator) void {
            self.present = false;
            self.cleared = true;
        }
    };

    var valid: Adapter = .{};
    const copied = dispatch(std.testing.allocator, .copy, &valid);
    defer switch (copied) {
        .copy => |text| std.testing.allocator.free(text),
        else => {},
    };
    try std.testing.expect(copied == .copy);
    try std.testing.expect(valid.present);

    var stale: Adapter = .{ .valid = false };
    try std.testing.expectEqual(DispatchTerminal.authority_invalid, dispatch(std.testing.allocator, .copy, &stale));
    try std.testing.expect(stale.cleared);

    var failing: Adapter = .{ .fail_allocation = true };
    try std.testing.expectEqual(DispatchTerminal.preparation_failed, dispatch(std.testing.allocator, .copy, &failing));
    try std.testing.expect(failing.present);

    var explicit: Adapter = .{};
    try std.testing.expectEqual(DispatchTerminal.cleared, dispatch(std.testing.allocator, .clear, &explicit));
    try std.testing.expect(explicit.cleared);
}

test "selection action projection maps source and virtual rows bidirectionally" {
    const projection = Projection.init(7, 2).?;
    try std.testing.expectEqual(@as(usize, 9), projection.presentationRows());
    try std.testing.expectEqual(@as(?usize, 0), projection.sourceToPresentation(0));
    try std.testing.expectEqual(@as(?usize, 2), projection.sourceToPresentation(2));
    try std.testing.expectEqual(@as(?usize, 5), projection.sourceToPresentation(3));
    try std.testing.expectEqual(Location{ .source = 2 }, projection.locate(2).?);
    try std.testing.expectEqual(Location{ .action = .summary }, projection.locate(3).?);
    try std.testing.expectEqual(Location{ .action = .controls }, projection.locate(4).?);
    try std.testing.expectEqual(Location{ .source = 3 }, projection.locate(5).?);
}

test "selection action projection skips action rows with directional bias" {
    const projection = Projection.init(5, 2).?;
    try std.testing.expectEqual(@as(?usize, 2), projection.nearestSource(3, .before));
    try std.testing.expectEqual(@as(?usize, 3), projection.nearestSource(3, .after));
    try std.testing.expectEqual(@as(?usize, 2), projection.nearestSource(4, .before));
    try std.testing.expectEqual(@as(?usize, 3), projection.nearestSource(4, .after));

    const eof = Projection.init(3, 2).?;
    try std.testing.expectEqual(@as(?usize, 2), eof.nearestSource(3, .after));
    try std.testing.expectEqual(@as(?usize, 2), eof.nearestSource(4, .before));
}

test "selection action reveal saturates for normal tiny and zero viewports" {
    const projection = Projection.init(10, 7).?;
    try std.testing.expectEqual(@as(usize, 5), projection.reveal(0, 5));
    try std.testing.expectEqual(@as(usize, 7), projection.reveal(99, 4));
    try std.testing.expectEqual(@as(usize, 12), projection.reveal(99, 0));
    try std.testing.expectEqual(@as(?usize, 2), projection.actionScreenRow(.summary, 6, 5));
    try std.testing.expectEqual(@as(?usize, 3), projection.actionScreenRow(.controls, 6, 5));
}

test "selection action layout exposes only complete rendered targets" {
    const wide = actionLayout(.{ .col = 3, .width = 40 });
    try std.testing.expectEqual(Action.copy, wide.targetAt(3, .controls).?);
    try std.testing.expectEqual(Action.clear, wide.targetAt(12, .controls).?);
    try std.testing.expect(wide.targetAt(3, .summary) == null);

    const narrow = actionLayout(.{ .col = 0, .width = 10 });
    try std.testing.expect(narrow.copy != null);
    try std.testing.expect(narrow.clear == null);
    try std.testing.expect(narrow.targetAt(9, .controls) == null);
}

test "selection viewport anchor removes projection without raw ordinal reuse" {
    const projection = Projection.init(8, 2).?;
    const basis: ProjectionBasis = .{
        .layout_revision = 1,
        .source_rows = 8,
        .action_insertion_offset = projection.insertionOffset(),
    };
    const position = captureAnchorPosition(8, projection, 3);
    const Anchor = ViewportAnchor(usize);
    const anchor: Anchor = .{
        .semantic_source = position.source_offset_fallback,
        .source_offset_fallback = position.source_offset_fallback,
        .signed_screen_delta = position.signed_screen_delta,
        .raw_presentation_scroll = 3,
        .basis = basis,
    };
    try std.testing.expectEqual(@as(usize, 1), restoreViewportAnchor(anchor, .{
        .layout_revision = 2,
        .source_rows = 8,
        .action_insertion_offset = null,
    }, null, 3, 4));

    const eof = Projection.init(4, 3).?;
    const eof_position = captureAnchorPosition(4, eof, 5);
    const eof_anchor: Anchor = .{
        .semantic_source = eof_position.source_offset_fallback,
        .source_offset_fallback = eof_position.source_offset_fallback,
        .signed_screen_delta = eof_position.signed_screen_delta,
        .raw_presentation_scroll = 5,
        .basis = .{
            .layout_revision = 1,
            .source_rows = 4,
            .action_insertion_offset = eof.insertionOffset(),
        },
    };
    try std.testing.expectEqual(@as(usize, 3), eof_anchor.source_offset_fallback);
    try std.testing.expectEqual(@as(isize, -2), eof_anchor.signed_screen_delta);
    try std.testing.expectEqual(@as(usize, 5), restoreViewportAnchor(eof_anchor, .{
        .layout_revision = 2,
        .source_rows = 8,
        .action_insertion_offset = null,
    }, null, null, 2));

    const same_projection = Projection.init(12, 4).?;
    const same_basis: ProjectionBasis = .{
        .layout_revision = 9,
        .mapping_variant = 1,
        .source_rows = 12,
        .action_insertion_offset = same_projection.insertionOffset(),
    };
    const same_anchor: Anchor = .{
        .semantic_source = 5,
        .source_offset_fallback = 5,
        .signed_screen_delta = 0,
        .raw_presentation_scroll = 7,
        .basis = same_basis,
    };
    try std.testing.expectEqual(
        @as(usize, 7),
        restoreViewportAnchor(same_anchor, same_basis, same_projection, 1, 3),
    );
    const changed = Projection.init(9, 1).?;
    try std.testing.expectEqual(@as(usize, 6), restoreViewportAnchor(same_anchor, .{
        .layout_revision = 10,
        .mapping_variant = 0,
        .source_rows = 9,
        .action_insertion_offset = changed.insertionOffset(),
    }, changed, 4, 3));
}
