//! Responsibility-neutral retained-selection status and actions.
//!
//! Pages keep content identity, selected bytes, ranges, and lifecycle
//! authority. This module owns only the shared Copy/Clear action vocabulary,
//! fixed one-row status presentation, clipped hit geometry, dispatch terminals,
//! and allocation-free viewport arithmetic.

const std = @import("std");
const chasen = @import("chasen");
const draw = @import("draw");

pub const Action = enum {
    copy,
    clear,
};

pub fn advanceGeneration(generation: *u64) u64 {
    generation.* +%= 1;
    if (generation.* == 0) generation.* = 1;
    return generation.*;
}

pub const copy_control_text = " y Copy ";
pub const clear_control_text = " Esc Clear ";
pub const controls_text = copy_control_text ++ " " ++ clear_control_text;
const default_line_count_width: usize = 2;

/// Pane-local selection status. Diff panes map their semantic old/new side to
/// before/after, while Repository source selections have no side qualifier.
pub const StatusSide = enum {
    none,
    before,
    after,
};

pub const StatusPresentation = struct {
    line_count: usize,
    side: StatusSide = .none,
};

const StatusVariant = enum {
    full,
    compact,
    tight,
    actions_only,
};

pub const StatusLayout = struct {
    region: Region,
    copy: ?Region,
    clear: ?Region,

    pub fn targetAt(self: StatusLayout, col: u16) ?Action {
        if (self.copy) |region| if (region.contains(col)) return .copy;
        if (self.clear) |region| if (region.contains(col)) return .clear;
        return null;
    }
};

/// Resolve the exact hit geometry used by the fixed command/status row. The
/// prefix sheds decoration before either complete action label is clipped.
pub fn statusLayout(region: Region, presentation: StatusPresentation) StatusLayout {
    const prefix_width: u16 = @intCast(statusPrefixWidth(
        statusVariant(region.width, presentation),
        presentation,
    ));
    const copy_width: u16 = @intCast(chasen.text.displayWidth(copy_control_text));
    const clear_width: u16 = @intCast(chasen.text.displayWidth(clear_control_text));
    const copy_col = region.col +| prefix_width;
    const clear_col = copy_col +| copy_width +| 1;
    const end = region.col +| region.width;
    return .{
        .region = region,
        .copy = if (copy_col +| copy_width <= end) .{ .col = copy_col, .width = copy_width } else null,
        .clear = if (clear_col +| clear_width <= end) .{ .col = clear_col, .width = clear_width } else null,
    };
}

/// Draw the one-row selection mode presentation into an already-reserved
/// pane header row. This never changes body geometry or scroll coordinates.
pub fn drawStatusLine(
    surface: *chasen.Surface,
    row: u16,
    region: Region,
    presentation: StatusPresentation,
    style: chasen.TextStyle,
    button_foreground: chasen.Color,
    button_background: chasen.Color,
) !void {
    if (row >= surface.size().height or region.width == 0 or region.col >= surface.size().width) return;
    const width = @min(region.width, surface.size().width - region.col);
    surface.fill(.{
        .col = region.col,
        .row = row,
        .width = width,
        .height = 1,
    }, .{ .style = style });
    const effective_region: Region = .{ .col = region.col, .width = width };
    const layout = statusLayout(effective_region, presentation);
    var line_surface = surface.child(.{
        .col = effective_region.col,
        .row = row,
        .width = effective_region.width,
        .height = 1,
    });
    const variant = statusVariant(width, presentation);
    const prefix = try statusPrefixAlloc(surface.frameAllocator(), variant, presentation);
    try draw.copyClippedTextAt(&line_surface, 0, 0, prefix, style);
    const prefix_width: u16 = @intCast(chasen.text.displayWidth(prefix));
    if (prefix_width >= width) return;

    var button_style = style;
    button_style.fg = button_foreground;
    button_style.bg = button_background;
    if (layout.copy) |target| try draw.copyClippedTextAt(
        &line_surface,
        target.col - effective_region.col,
        0,
        copy_control_text,
        button_style,
    );
    if (layout.clear) |target| try draw.copyClippedTextAt(
        &line_surface,
        target.col - effective_region.col,
        0,
        clear_control_text,
        button_style,
    );
}

fn statusVariant(width: u16, presentation: StatusPresentation) StatusVariant {
    const controls_width = chasen.text.displayWidth(controls_text);
    const copy_width = chasen.text.displayWidth(copy_control_text);
    if (statusPrefixWidth(.full, presentation) + controls_width <= width) return .full;
    if (statusPrefixWidth(.compact, presentation) + controls_width <= width) return .compact;
    if (statusPrefixWidth(.tight, presentation) + controls_width <= width) return .tight;
    if (controls_width <= width) return .actions_only;
    if (statusPrefixWidth(.tight, presentation) + copy_width <= width) return .tight;
    return .actions_only;
}

fn statusPrefixWidth(variant: StatusVariant, presentation: StatusPresentation) usize {
    if (variant == .actions_only) return 0;
    return chasen.text.displayWidth(statusLead(variant, presentation.side)) +
        @max(decimalDigits(presentation.line_count), default_line_count_width) +
        chasen.text.displayWidth(statusTail(variant));
}

fn statusPrefixAlloc(
    allocator: std.mem.Allocator,
    variant: StatusVariant,
    presentation: StatusPresentation,
) ![]const u8 {
    if (variant == .actions_only) return "";
    return std.fmt.allocPrint(allocator, "{s}{d: >2}{s}", .{
        statusLead(variant, presentation.side),
        presentation.line_count,
        statusTail(variant),
    });
}

fn statusLead(variant: StatusVariant, side: StatusSide) []const u8 {
    return switch (variant) {
        .full => switch (side) {
            .none => "VISUAL · ",
            .before => "VISUAL · BEFORE · ",
            .after => "VISUAL · AFTER  · ",
        },
        .compact => switch (side) {
            .none => "",
            .before => "BEFORE · ",
            .after => "AFTER  · ",
        },
        .tight => switch (side) {
            .none => "",
            .before => "B · ",
            .after => "A · ",
        },
        .actions_only => "",
    };
}

fn statusTail(variant: StatusVariant) []const u8 {
    return switch (variant) {
        .full, .compact => " lines selected ",
        .tight => "L ",
        .actions_only => "",
    };
}

fn decimalDigits(value: usize) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) : (remaining /= 10) digits += 1;
    return digits;
}

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

pub const Region = struct {
    col: u16,
    width: u16,

    pub fn contains(self: Region, col: u16) bool {
        return col >= self.col and col < self.col +| self.width;
    }
};

/// Scalar identity of one source/presentation mapping. `mapping_variant` is
/// an opaque page-provided discriminator (for example a diff display mode);
/// this module never interprets it.
pub const ViewportBasis = struct {
    layout_revision: u64,
    mapping_variant: u8 = 0,
    source_rows: usize,

    pub fn eql(self: ViewportBasis, other: ViewportBasis) bool {
        return std.meta.eql(self, other);
    }

    pub fn maxScroll(self: ViewportBasis, visible_rows: usize) usize {
        return self.source_rows -| visible_rows;
    }

    pub fn clampScroll(self: ViewportBasis, scroll: usize, visible_rows: usize) usize {
        return @min(scroll, self.maxScroll(visible_rows));
    }
};

pub const AnchorPosition = struct {
    source_offset_fallback: usize,
};

pub fn ViewportAnchor(comptime SemanticSource: type) type {
    return struct {
        semantic_source: SemanticSource,
        source_offset_fallback: usize,
        raw_presentation_scroll: usize,
        basis: ViewportBasis,
    };
}

pub fn captureAnchorPosition(
    source_rows: usize,
    source_scroll: usize,
) AnchorPosition {
    if (source_rows == 0) return .{ .source_offset_fallback = 0 };
    return .{
        .source_offset_fallback = @min(source_scroll, source_rows - 1),
    };
}

pub fn restoreViewportAnchor(
    anchor: anytype,
    incoming_basis: ViewportBasis,
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
    return incoming_basis.clampScroll(source, visible_rows);
}

test "selection action maps exact keys without command modifiers" {
    try std.testing.expectEqual(Action.copy, keyToAction(.{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(Action.clear, keyToAction(.{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expect(keyToAction(.{ .codepoint = 'y', .mods = .{ .ctrl = true } }) == null);
}

test "fixed selection status exposes complete actions from wide to narrow panes" {
    const presentation: StatusPresentation = .{ .line_count = 12, .side = .before };
    const wide = statusLayout(.{ .col = 1, .width = 70 }, presentation);
    try std.testing.expect(wide.copy != null);
    try std.testing.expect(wide.clear != null);
    try std.testing.expectEqual(Action.copy, wide.targetAt(wide.copy.?.col).?);
    try std.testing.expectEqual(Action.clear, wide.targetAt(wide.clear.?.col).?);

    const exact_controls = statusLayout(.{ .col = 0, .width = 20 }, presentation);
    try std.testing.expectEqual(Region{ .col = 0, .width = 8 }, exact_controls.copy.?);
    try std.testing.expectEqual(Region{ .col = 9, .width = 11 }, exact_controls.clear.?);
    try std.testing.expectEqual(Action.clear, exact_controls.targetAt(19).?);

    const repository_minimum = statusLayout(.{ .col = 1, .width = 23 }, presentation);
    try std.testing.expect(repository_minimum.copy != null);
    try std.testing.expect(repository_minimum.clear != null);

    const copy_with_count = statusLayout(.{ .col = 0, .width = 19 }, presentation);
    try std.testing.expectEqual(Region{ .col = 8, .width = 8 }, copy_with_count.copy.?);
    try std.testing.expect(copy_with_count.clear == null);

    const narrow = statusLayout(.{ .col = 1, .width = 9 }, presentation);
    try std.testing.expectEqual(Region{ .col = 1, .width = 8 }, narrow.copy.?);
    try std.testing.expect(narrow.clear == null);
    try std.testing.expectEqual(Action.copy, narrow.targetAt(1).?);
    try std.testing.expect(narrow.targetAt(9) == null);

    const one_digit = statusLayout(.{ .col = 1, .width = 70 }, .{ .line_count = 9 });
    const two_digits = statusLayout(.{ .col = 1, .width = 70 }, .{ .line_count = 10 });
    try std.testing.expectEqual(one_digit.copy.?.col, two_digits.copy.?.col);
    try std.testing.expectEqual(one_digit.clear.?.col, two_digits.clear.?.col);
}

test "fixed selection status never draws a partial mouse action" {
    const allocator = std.testing.allocator;
    const presentation: StatusPresentation = .{ .line_count = 12, .side = .before };
    const foreground: chasen.Color = .{ .rgb = .{ 234, 251, 255 } };
    const background: chasen.Color = .{ .rgb = .{ 49, 93, 112 } };

    var copy_only: chasen.testing.TestSurface = undefined;
    try copy_only.init(19, 1);
    defer copy_only.deinit();
    try drawStatusLine(&copy_only.surface, 0, .{ .col = 0, .width = 19 }, presentation, .{}, foreground, background);
    const copy_only_snapshot = try copy_only.snapshot(allocator);
    defer allocator.free(copy_only_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, copy_only_snapshot, "y Copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, copy_only_snapshot, "Esc Clear") == null);

    var both: chasen.testing.TestSurface = undefined;
    try both.init(23, 1);
    defer both.deinit();
    try drawStatusLine(&both.surface, 0, .{ .col = 0, .width = 23 }, presentation, .{}, foreground, background);
    const both_snapshot = try both.snapshot(allocator);
    defer allocator.free(both_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, both_snapshot, "y Copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, both_snapshot, "Esc Clear") != null);
}

test "fixed selection status paints separate button foregrounds and backgrounds" {
    var test_surface: chasen.testing.TestSurface = undefined;
    try test_surface.init(48, 1);
    defer test_surface.deinit();
    const label: chasen.Color = .{ .rgb = .{ 180, 142, 173 } };
    const foreground: chasen.Color = .{ .rgb = .{ 234, 251, 255 } };
    const background: chasen.Color = .{ .rgb = .{ 45, 48, 58 } };
    const presentation: StatusPresentation = .{ .line_count = 9 };
    const region: Region = .{ .col = 0, .width = 48 };

    try drawStatusLine(&test_surface.surface, 0, region, presentation, .{ .fg = label }, foreground, background);
    const layout = statusLayout(region, presentation);
    try std.testing.expect(test_surface.surface.readCell(0, 0).?.style.fg.eql(label));
    try std.testing.expect(test_surface.surface.readCell(layout.copy.?.col, 0).?.style.fg.eql(foreground));
    try std.testing.expect(test_surface.surface.readCell(layout.clear.?.col, 0).?.style.fg.eql(foreground));
    try std.testing.expect(test_surface.surface.readCell(layout.copy.?.col, 0).?.style.bg.eql(background));
    try std.testing.expect(test_surface.surface.readCell(layout.clear.?.col, 0).?.style.bg.eql(background));
    try std.testing.expect(test_surface.surface.readCell(layout.copy.?.col + layout.copy.?.width, 0).?.style.bg.eql(.default));
}

test "selection generation is monotonic and never uses zero" {
    var generation: u64 = 0;
    try std.testing.expectEqual(@as(u64, 1), advanceGeneration(&generation));
    generation = std.math.maxInt(u64);
    try std.testing.expectEqual(@as(u64, 1), advanceGeneration(&generation));
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

test "selection viewport anchor restores semantic source after basis changes" {
    const basis: ViewportBasis = .{
        .layout_revision = 1,
        .source_rows = 8,
    };
    const position = captureAnchorPosition(8, 3);
    const Anchor = ViewportAnchor(usize);
    const anchor: Anchor = .{
        .semantic_source = position.source_offset_fallback,
        .source_offset_fallback = position.source_offset_fallback,
        .raw_presentation_scroll = 3,
        .basis = basis,
    };
    try std.testing.expectEqual(@as(usize, 3), restoreViewportAnchor(anchor, .{
        .layout_revision = 2,
        .source_rows = 8,
    }, 3, 4));

    const eof_position = captureAnchorPosition(4, 5);
    const eof_anchor: Anchor = .{
        .semantic_source = eof_position.source_offset_fallback,
        .source_offset_fallback = eof_position.source_offset_fallback,
        .raw_presentation_scroll = 5,
        .basis = .{
            .layout_revision = 1,
            .source_rows = 4,
        },
    };
    try std.testing.expectEqual(@as(usize, 3), eof_anchor.source_offset_fallback);
    try std.testing.expectEqual(@as(usize, 3), restoreViewportAnchor(eof_anchor, .{
        .layout_revision = 2,
        .source_rows = 8,
    }, null, 2));

    const same_basis: ViewportBasis = .{
        .layout_revision = 9,
        .mapping_variant = 1,
        .source_rows = 12,
    };
    const same_anchor: Anchor = .{
        .semantic_source = 5,
        .source_offset_fallback = 5,
        .raw_presentation_scroll = 7,
        .basis = same_basis,
    };
    try std.testing.expectEqual(
        @as(usize, 7),
        restoreViewportAnchor(same_anchor, same_basis, 1, 3),
    );
    try std.testing.expectEqual(@as(usize, 4), restoreViewportAnchor(same_anchor, .{
        .layout_revision = 10,
        .mapping_variant = 0,
        .source_rows = 9,
    }, 4, 3));
}
