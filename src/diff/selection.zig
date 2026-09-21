const std = @import("std");
const diff_file = @import("file.zig");
const diff_parser = @import("parser.zig");
const text_projection = @import("chasen_ui").text_projection;

const review_tab_width: usize = 4;

pub const Side = enum {
    old,
    new,
};

pub const Mode = enum {
    line,
    character,
};

/// What the user is selecting, independent of how the diff happens to be
/// laid out on screen. Unified selections are whole diff rows and therefore
/// deliberately have neither a source side nor a character mode.
pub const Content = union(enum) {
    source_side: SourceSide,
    unified_diff,

    pub const SourceSide = struct {
        side: Side,
        mode: Mode = .line,
    };

    pub fn sourceSide(self: Content) ?SourceSide {
        return switch (self) {
            .source_side => |source| source,
            .unified_diff => null,
        };
    }

    pub fn mode(self: Content) Mode {
        return switch (self) {
            .source_side => |source| source.mode,
            .unified_diff => .line,
        };
    }

    pub fn isUnified(self: Content) bool {
        return self == .unified_diff;
    }
};

pub const Origin = enum {
    mouse,
    keyboard_line,
};

pub const Point = struct {
    hunk_index: usize,
    line_index: usize,
    /// Byte boundaries for character mode. Line mode ignores these fields.
    leading: usize = 0,
    trailing: usize = 0,

    pub fn order(self: Point, other: Point) std.math.Order {
        if (self.hunk_index != other.hunk_index) return std.math.order(self.hunk_index, other.hunk_index);
        if (self.line_index != other.line_index) return std.math.order(self.line_index, other.line_index);
        if (self.leading != other.leading) return std.math.order(self.leading, other.leading);
        return std.math.order(self.trailing, other.trailing);
    }

    pub fn eql(self: Point, other: Point) bool {
        return self.order(other) == .eq;
    }

    fn beforeOrEqual(self: Point, other: Point) bool {
        return self.order(other) != .gt;
    }
};

pub const Range = struct {
    start: Point,
    end: Point,

    pub fn contains(self: Range, point: Point) bool {
        return self.start.beforeOrEqual(point) and point.beforeOrEqual(self.end);
    }
};

pub const Identity = union(enum) {
    loaded_file: struct {
        file_index: usize,
        /// Borrowed from the loaded diff arena. Active selections must be
        /// cleared before the loaded session is destroyed or replaced.
        path_key: []const u8,
    },
    projection_file: struct {
        kind: enum { cached, combined },
        path_key: []const u8,
    },
    generated_file: struct {
        path_key: []const u8,
    },

    pub fn matchesLoadedFile(self: Identity, file_index: usize, file: diff_parser.FileDiff) bool {
        return switch (self) {
            .loaded_file => |loaded| blk: {
                if (loaded.file_index != file_index) break :blk false;
                const key = diff_file.canonicalPathKey(file) orelse break :blk false;
                break :blk std.mem.eql(u8, loaded.path_key, key);
            },
            .projection_file, .generated_file => false,
        };
    }

    pub fn eql(self: Identity, other: Identity) bool {
        return switch (self) {
            .loaded_file => |loaded| switch (other) {
                .loaded_file => |other_loaded| loaded.file_index == other_loaded.file_index and
                    std.mem.eql(u8, loaded.path_key, other_loaded.path_key),
                .projection_file, .generated_file => false,
            },
            .projection_file => |projected| switch (other) {
                .projection_file => |other_projected| projected.kind == other_projected.kind and
                    std.mem.eql(u8, projected.path_key, other_projected.path_key),
                .loaded_file, .generated_file => false,
            },
            .generated_file => |generated| switch (other) {
                .generated_file => |other_generated| std.mem.eql(u8, generated.path_key, other_generated.path_key),
                .loaded_file, .projection_file => false,
            },
        };
    }
};

pub const HeaderKind = enum {
    loaded_file,
    generated_file,
    projection_file,
};

pub const HeaderIdentity = struct {
    kind: HeaderKind,
    /// Borrowed from the active loaded/projection arena. Active selections must
    /// be cleared before the owning session/projection is destroyed or replaced.
    path_key: []const u8,

    pub fn eql(self: HeaderIdentity, other: HeaderIdentity) bool {
        return self.kind == other.kind and std.mem.eql(u8, self.path_key, other.path_key);
    }
};

pub const HeaderPathSelection = struct {
    identity: HeaderIdentity,
    moved: bool = false,

    pub fn update(self: *HeaderPathSelection) void {
        self.moved = true;
    }
};

pub const KeyboardSideChoice = struct {
    identity: Identity,
    before: Point,
    after: Point,
};

pub const DragSelection = struct {
    identity: Identity,
    content: Content,
    origin: Origin = .mouse,
    anchor: Point,
    focus: Point,
    moved: bool = false,
    anchor_cell: ?Cell = null,
    /// Allocation-free active keyboard count. Mouse selections derive their
    /// owned count only when completion builds fragments.
    selected_line_count: usize = 0,

    pub fn init(identity: Identity, side: Side, point: Point) DragSelection {
        return .{
            .identity = identity,
            .content = .{ .source_side = .{ .side = side } },
            .anchor = point,
            .focus = point,
        };
    }

    pub fn initAtCell(identity: Identity, side: Side, selection_mode: Mode, point: Point, cell: Cell) DragSelection {
        return initContentAtCell(identity, .{ .source_side = .{ .side = side, .mode = selection_mode } }, point, cell);
    }

    pub fn initContentAtCell(identity: Identity, content: Content, point: Point, cell: Cell) DragSelection {
        return .{
            .identity = identity,
            .content = content,
            .anchor = point,
            .focus = point,
            .anchor_cell = cell,
        };
    }

    pub fn initKeyboardLine(identity: Identity, side: Side, point: Point) DragSelection {
        return initContentKeyboardLine(identity, .{ .source_side = .{ .side = side } }, point);
    }

    pub fn initContentKeyboardLine(identity: Identity, content: Content, point: Point) DragSelection {
        return .{
            .identity = identity,
            .content = content,
            .origin = .keyboard_line,
            .anchor = point,
            .focus = point,
            .moved = true,
            .selected_line_count = 1,
        };
    }

    pub fn initUnified(identity: Identity, point: Point) DragSelection {
        return .{
            .identity = identity,
            .content = .unified_diff,
            .anchor = point,
            .focus = point,
        };
    }

    pub fn initUnifiedAtCell(identity: Identity, point: Point, cell: Cell) DragSelection {
        return .{
            .identity = identity,
            .content = .unified_diff,
            .anchor = point,
            .focus = point,
            .anchor_cell = cell,
        };
    }

    pub fn initUnifiedKeyboardLine(identity: Identity, point: Point) DragSelection {
        return initContentKeyboardLine(identity, .unified_diff, point);
    }

    pub fn sourceSide(self: DragSelection) ?Content.SourceSide {
        return self.content.sourceSide();
    }

    pub fn mode(self: DragSelection) Mode {
        return self.content.mode();
    }

    pub fn selectedSide(self: DragSelection) ?Side {
        const source = self.sourceSide() orelse return null;
        return source.side;
    }

    pub fn update(self: *DragSelection, point: Point) void {
        if (point.hunk_index != self.focus.hunk_index or point.line_index != self.focus.line_index or
            point.leading != self.focus.leading or point.trailing != self.focus.trailing)
        {
            self.moved = true;
        }
        self.focus = point;
    }

    pub fn updateAtCell(self: *DragSelection, point: Point, cell: Cell) void {
        if (self.anchor_cell) |anchor_cell| {
            if (!anchor_cell.eql(cell)) self.moved = true;
        }
        self.focus = point;
    }

    pub fn updateKeyboardLine(self: *DragSelection, point: Point, selected_line_count: usize) void {
        std.debug.assert(self.origin == .keyboard_line);
        std.debug.assert(self.mode() == .line);
        std.debug.assert(selected_line_count > 0);
        self.update(point);
        self.selected_line_count = selected_line_count;
    }

    pub fn range(self: DragSelection) Range {
        if (self.anchor.beforeOrEqual(self.focus)) {
            return .{ .start = self.anchor, .end = self.focus };
        }
        return .{ .start = self.focus, .end = self.anchor };
    }

    pub fn view(self: DragSelection) View {
        const selected_range = self.range();
        return .{
            .identity = self.identity,
            .content = self.content,
            .start = selected_range.start,
            .end = selected_range.end,
        };
    }
};

pub const Cell = struct {
    col: u16,
    row: u16,

    pub fn eql(self: Cell, other: Cell) bool {
        return self.col == other.col and self.row == other.row;
    }
};

pub const Owner = union(enum) {
    none,
    diff: DragSelection,
    diff_header: HeaderPathSelection,
    keyboard_side_choice: KeyboardSideChoice,

    pub fn activeDiff(self: Owner) ?DragSelection {
        return switch (self) {
            .none => null,
            .diff => |selection| selection,
            .diff_header, .keyboard_side_choice => null,
        };
    }

    pub fn activeHeader(self: Owner) ?HeaderPathSelection {
        return switch (self) {
            .none, .diff, .keyboard_side_choice => null,
            .diff_header => |selection| selection,
        };
    }

    pub fn activeKeyboardSideChoice(self: Owner) ?KeyboardSideChoice {
        return switch (self) {
            .keyboard_side_choice => |choice| choice,
            .none, .diff, .diff_header => null,
        };
    }

    pub fn activeMouseSelection(self: Owner) bool {
        return switch (self) {
            .none, .keyboard_side_choice => false,
            .diff => |selection| selection.origin == .mouse,
            .diff_header => true,
        };
    }

    pub fn activeKeyboardLineSelection(self: Owner) bool {
        return switch (self) {
            .diff => |selection| selection.origin == .keyboard_line,
            .none, .diff_header, .keyboard_side_choice => false,
        };
    }
};

pub const View = struct {
    identity: Identity,
    content: Content,
    start: Point,
    end: Point,
    /// Present only for retained unified selections. These points describe
    /// the exact visible rows captured at release, so later rendering never
    /// expands a retained range across folded or newly visible rows.
    selected_points: ?[]const Point = null,

    pub fn range(self: View) Range {
        return .{ .start = self.start, .end = self.end };
    }

    pub fn sourceSide(self: View) ?Content.SourceSide {
        return self.content.sourceSide();
    }

    pub fn mode(self: View) Mode {
        return self.content.mode();
    }

    pub fn selectedSide(self: View) ?Side {
        const source = self.sourceSide() orelse return null;
        return source.side;
    }
};

pub const LineVisualRange = struct {
    mode: Mode,
    byte_start: usize,
    byte_end: usize,
};

pub fn visualRangeForLine(view: View, hunk_index: usize, line_index: usize, line: diff_parser.DiffLine, side: ?Side) ?LineVisualRange {
    const mode = switch (view.content) {
        .source_side => |source| blk: {
            const rendered_side = side orelse return null;
            if (source.side != rendered_side or !lineVisibleOnSide(line, rendered_side)) return null;
            break :blk source.mode;
        },
        .unified_diff => blk: {
            if (side != null or !lineSelectableInUnified(line)) return null;
            if (view.selected_points) |points| {
                if (!containsPoint(points, pointFromLine(hunk_index, line_index))) return null;
            }
            break :blk .line;
        },
    };
    const range = view.range();
    if (hunk_index < range.start.hunk_index or hunk_index > range.end.hunk_index) return null;
    if (hunk_index == range.start.hunk_index and line_index < range.start.line_index) return null;
    if (hunk_index == range.end.hunk_index and line_index > range.end.line_index) return null;
    const bytes = selectedBytesForLine(line.text, mode, range, hunk_index, line_index) orelse return null;
    if (mode == .character and bytes.start == bytes.end) return null;
    return .{ .mode = mode, .byte_start = bytes.start, .byte_end = bytes.end };
}

fn containsPoint(points: []const Point, needle: Point) bool {
    for (points) |point| if (point.eql(needle)) return true;
    return false;
}

pub fn pointFromLine(hunk_index: usize, line_index: usize) Point {
    return .{ .hunk_index = hunk_index, .line_index = line_index };
}

pub fn pointFromToken(hunk_index: usize, line_index: usize, token: text_projection.Token) Point {
    return .{
        .hunk_index = hunk_index,
        .line_index = line_index,
        .leading = token.byte_start,
        .trailing = token.byte_end,
    };
}

pub fn pointFromBoundary(hunk_index: usize, line_index: usize, offset: usize) Point {
    return .{
        .hunk_index = hunk_index,
        .line_index = line_index,
        .leading = offset,
        .trailing = offset,
    };
}

pub fn lineVisibleOnSide(line: diff_parser.DiffLine, side: Side) bool {
    return switch (side) {
        .old => line.kind == .context or line.kind == .removed,
        .new => line.kind == .context or line.kind == .added,
    };
}

pub fn lineSelectableInUnified(line: diff_parser.DiffLine) bool {
    return switch (line.kind) {
        .context, .removed, .added => true,
        .metadata => false,
    };
}

pub fn unifiedMarker(line: diff_parser.DiffLine) ?u8 {
    return switch (line.kind) {
        .context => ' ',
        .removed => '-',
        .added => '+',
        .metadata => null,
    };
}

/// Number of semantic lines on `side` strictly after one endpoint through the
/// other endpoint. Both endpoints must identify selectable lines. This lets a
/// single presentation step account for folded hunks without rebuilding an
/// owned selection or rescanning the complete active range.
pub fn semanticLineDistance(file: diff_parser.FileDiff, side: Side, a: Point, b: Point) ?usize {
    if (a.eql(b)) return 0;
    const start = if (a.order(b) == .lt) a else b;
    const end = if (a.order(b) == .lt) b else a;
    if (!selectablePoint(file, side, start) or !selectablePoint(file, side, end)) return null;

    var count: usize = 0;
    var hunk_index = start.hunk_index;
    while (hunk_index <= end.hunk_index) : (hunk_index += 1) {
        const hunk = file.hunks[hunk_index];
        var line_index: usize = if (hunk_index == start.hunk_index) start.line_index + 1 else 0;
        const stop = if (hunk_index == end.hunk_index) end.line_index else hunk.lines.len -| 1;
        while (line_index < hunk.lines.len and line_index <= stop) : (line_index += 1) {
            if (lineVisibleOnSide(hunk.lines[line_index], side)) count += 1;
        }
    }
    return count;
}

/// Number of visible unified diff rows strictly after one endpoint through
/// the other endpoint. Folded hunks are not part of unified selection space.
pub fn unifiedLineDistance(file: diff_parser.FileDiff, folded_hunks: []const bool, a: Point, b: Point) ?usize {
    if (a.eql(b)) return 0;
    const start = if (a.order(b) == .lt) a else b;
    const end = if (a.order(b) == .lt) b else a;
    if (!selectableUnifiedPoint(file, folded_hunks, start) or !selectableUnifiedPoint(file, folded_hunks, end)) return null;

    var count: usize = 0;
    var hunk_index = start.hunk_index;
    while (hunk_index <= end.hunk_index) : (hunk_index += 1) {
        if (hunkIsFolded(folded_hunks, hunk_index)) continue;
        const hunk = file.hunks[hunk_index];
        var line_index: usize = if (hunk_index == start.hunk_index) start.line_index + 1 else 0;
        const stop = if (hunk_index == end.hunk_index) end.line_index else hunk.lines.len -| 1;
        while (line_index < hunk.lines.len and line_index <= stop) : (line_index += 1) {
            if (lineSelectableInUnified(hunk.lines[line_index])) count += 1;
        }
    }
    return count;
}

fn selectablePoint(file: diff_parser.FileDiff, side: Side, point: Point) bool {
    if (point.hunk_index >= file.hunks.len) return false;
    const hunk = file.hunks[point.hunk_index];
    if (point.line_index >= hunk.lines.len) return false;
    return lineVisibleOnSide(hunk.lines[point.line_index], side);
}

fn selectableUnifiedPoint(file: diff_parser.FileDiff, folded_hunks: []const bool, point: Point) bool {
    if (point.hunk_index >= file.hunks.len or hunkIsFolded(folded_hunks, point.hunk_index)) return false;
    const hunk = file.hunks[point.hunk_index];
    if (point.line_index >= hunk.lines.len) return false;
    return lineSelectableInUnified(hunk.lines[point.line_index]);
}

fn hunkIsFolded(folded_hunks: []const bool, hunk_index: usize) bool {
    return hunk_index < folded_hunks.len and folded_hunks[hunk_index];
}

pub fn copyText(
    allocator: std.mem.Allocator,
    file: diff_parser.FileDiff,
    selection: DragSelection,
) ![]u8 {
    return copyTextFolded(allocator, file, &.{}, selection);
}

pub fn copyTextFolded(
    allocator: std.mem.Allocator,
    file: diff_parser.FileDiff,
    folded_hunks: []const bool,
    selection: DragSelection,
) ![]u8 {
    return switch (selection.content) {
        .source_side => blk: {
            var fragments = try buildFragments(allocator, file, selection);
            defer fragments.deinit(allocator);
            break :blk fragments.clipboardText(allocator);
        },
        .unified_diff => blk: {
            var unified = try buildUnifiedDiff(allocator, file, folded_hunks, selection.range());
            defer unified.deinit(allocator);
            break :blk unified.clipboardText(allocator);
        },
    };
}

pub const OwnedFragment = struct {
    hunk_index: usize,
    source_start: u32,
    source_end: u32,
    text: []u8,
    line_count: usize,

    fn deinit(self: *OwnedFragment, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const OwnedFragments = struct {
    mode: Mode,
    items: []OwnedFragment,
    line_count: usize,

    pub fn deinit(self: *OwnedFragments, allocator: std.mem.Allocator) void {
        for (self.items) |*fragment| fragment.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }

    pub fn clipboardText(self: OwnedFragments, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        for (self.items, 0..) |fragment, index| {
            if (index > 0) try out.writer.writeByte('\n');
            try out.writer.writeAll(fragment.text);
        }
        if (self.mode == .line and self.line_count >= 2) try out.writer.writeByte('\n');
        return out.toOwnedSlice();
    }
};

pub const OwnedUnifiedDiff = struct {
    text: []u8,
    points: []Point,
    line_count: usize,

    pub fn deinit(self: *OwnedUnifiedDiff, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.points);
        self.* = undefined;
    }

    pub fn clipboardText(self: OwnedUnifiedDiff, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, self.text);
    }
};

pub fn buildUnifiedDiff(
    allocator: std.mem.Allocator,
    file: diff_parser.FileDiff,
    folded_hunks: []const bool,
    selected_range: Range,
) BuildFragmentsError!OwnedUnifiedDiff {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var points: std.ArrayList(Point) = .empty;
    errdefer points.deinit(allocator);

    if (selected_range.start.hunk_index < file.hunks.len and selected_range.end.hunk_index < file.hunks.len) {
        var hunk_index = selected_range.start.hunk_index;
        while (hunk_index <= selected_range.end.hunk_index) : (hunk_index += 1) {
            if (hunkIsFolded(folded_hunks, hunk_index)) continue;
            const hunk = file.hunks[hunk_index];
            if (hunk.lines.len == 0) continue;
            const start_line = if (hunk_index == selected_range.start.hunk_index) selected_range.start.line_index else 0;
            const end_line = if (hunk_index == selected_range.end.hunk_index) selected_range.end.line_index else hunk.lines.len - 1;
            if (start_line >= hunk.lines.len) continue;
            var line_index = start_line;
            while (line_index < hunk.lines.len and line_index <= end_line) : (line_index += 1) {
                const line = hunk.lines[line_index];
                const marker = unifiedMarker(line) orelse continue;
                if (points.items.len > 0) out.writer.writeByte('\n') catch return error.OutOfMemory;
                out.writer.writeByte(marker) catch return error.OutOfMemory;
                out.writer.writeAll(line.text) catch return error.OutOfMemory;
                points.append(allocator, pointFromLine(hunk_index, line_index)) catch return error.OutOfMemory;
            }
        }
    }

    if (points.items.len >= 2) out.writer.writeByte('\n') catch return error.OutOfMemory;
    const text = try out.toOwnedSlice();
    errdefer allocator.free(text);
    const owned_points = try points.toOwnedSlice(allocator);
    return .{ .text = text, .points = owned_points, .line_count = owned_points.len };
}

pub const BuildFragmentsError = error{ InvalidSelection, OutOfMemory };

pub fn buildFragments(allocator: std.mem.Allocator, file: diff_parser.FileDiff, selection: DragSelection) BuildFragmentsError!OwnedFragments {
    const source = selection.sourceSide() orelse return error.InvalidSelection;
    const selected_range = selection.range();
    if (selected_range.start.hunk_index >= file.hunks.len or selected_range.end.hunk_index >= file.hunks.len) {
        return .{ .mode = source.mode, .items = try allocator.alloc(OwnedFragment, 0), .line_count = 0 };
    }

    var fragments: std.ArrayList(OwnedFragment) = .empty;
    errdefer {
        for (fragments.items) |*fragment| fragment.deinit(allocator);
        fragments.deinit(allocator);
    }
    var total_line_count: usize = 0;
    var hunk_index = selected_range.start.hunk_index;
    while (hunk_index <= selected_range.end.hunk_index) : (hunk_index += 1) {
        const hunk = file.hunks[hunk_index];
        const start_line = if (hunk_index == selected_range.start.hunk_index) selected_range.start.line_index else 0;
        const end_line = if (hunk_index == selected_range.end.hunk_index) selected_range.end.line_index else hunk.lines.len -| 1;
        if (start_line >= hunk.lines.len or hunk.lines.len == 0) continue;
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        var fragment_line_count: usize = 0;
        var source_start: ?u32 = null;
        var source_end: u32 = 0;
        var line_index = start_line;
        while (line_index < hunk.lines.len and line_index <= end_line) : (line_index += 1) {
            const line = hunk.lines[line_index];
            if (!lineVisibleOnSide(line, source.side)) continue;
            const range = selectedBytesForLine(line.text, source.mode, selected_range, hunk_index, line_index) orelse continue;
            if (range.start > range.end or range.end > line.text.len) return error.InvalidSelection;
            const projection = text_projection.Projection.init(line.text, .{ .tab_width = review_tab_width }) catch return error.InvalidSelection;
            if (!projection.isBoundary(range.start) or !projection.isBoundary(range.end)) return error.InvalidSelection;
            if (range.start == range.end and selected_range.start.hunk_index == selected_range.end.hunk_index and
                selected_range.start.line_index == selected_range.end.line_index) continue;
            if (fragment_line_count > 0) out.writer.writeByte('\n') catch return error.OutOfMemory;
            out.writer.writeAll(line.text[range.start..range.end]) catch return error.OutOfMemory;
            const source_line = lineNumberForSide(line, source.side) orelse return error.InvalidSelection;
            if (source_start == null) source_start = source_line;
            source_end = source_line;
            fragment_line_count += 1;
        }
        if (fragment_line_count == 0) {
            out.deinit();
            continue;
        }
        const text = try out.toOwnedSlice();
        fragments.append(allocator, .{
            .hunk_index = hunk_index,
            .source_start = source_start.?,
            .source_end = source_end,
            .text = text,
            .line_count = fragment_line_count,
        }) catch |err| {
            allocator.free(text);
            return err;
        };
        total_line_count += fragment_line_count;
    }

    return .{
        .mode = source.mode,
        .items = try fragments.toOwnedSlice(allocator),
        .line_count = total_line_count,
    };
}

const ByteRange = struct { start: usize, end: usize };

fn selectedBytesForLine(text: []const u8, mode: Mode, range: Range, hunk_index: usize, line_index: usize) ?ByteRange {
    if (mode == .line) return .{ .start = 0, .end = text.len };
    var start: usize = 0;
    var end: usize = text.len;
    if (hunk_index == range.start.hunk_index and line_index == range.start.line_index) start = range.start.leading;
    if (hunk_index == range.end.hunk_index and line_index == range.end.line_index) end = range.end.trailing;
    if (start > end) return null;
    return .{ .start = start, .end = end };
}

fn lineNumberForSide(line: diff_parser.DiffLine, side: Side) ?u32 {
    return switch (side) {
        .old => line.old_line,
        .new => line.new_line,
    };
}

test "copyText preserves side-specific lines and whitespace" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 3,
            .new_start = 1,
            .new_count = 3,
            .section = "",
            .lines = &.{
                .{ .kind = .context, .text = " same ", .old_line = 1, .new_line = 1 },
                .{ .kind = .removed, .text = "", .old_line = 2 },
                .{ .kind = .added, .text = "  new", .new_line = 2 },
            },
        }},
    };

    const identity: Identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } };
    const old_text = try copyText(std.testing.allocator, file, .{
        .identity = identity,
        .content = .{ .source_side = .{ .side = .old } },
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 2 },
        .moved = true,
    });
    defer std.testing.allocator.free(old_text);
    try std.testing.expectEqualStrings(" same \n\n", old_text);

    const new_text = try copyText(std.testing.allocator, file, .{
        .identity = identity,
        .content = .{ .source_side = .{ .side = .new } },
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 2 },
        .moved = true,
    });
    defer std.testing.allocator.free(new_text);
    try std.testing.expectEqualStrings(" same \n  new\n", new_text);
}

test "unified diff selection copies exact visible marker-prefixed logical rows" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .metadata = &.{"index 1..2"},
        .hunks = &.{
            .{
                .header = "@@ -1,2 +1,2 @@",
                .old_start = 1,
                .old_count = 2,
                .new_start = 1,
                .new_count = 2,
                .section = "",
                .lines = &.{
                    .{ .kind = .context, .text = "same", .old_line = 1, .new_line = 1 },
                    .{ .kind = .removed, .text = "old", .old_line = 2 },
                    .{ .kind = .added, .text = "new", .new_line = 2 },
                    .{ .kind = .metadata, .text = "\\ No newline at end of file" },
                },
            },
            .{
                .header = "@@ -9 +9 @@",
                .old_start = 9,
                .old_count = 1,
                .new_start = 9,
                .new_count = 1,
                .section = "",
                .lines = &.{.{ .kind = .context, .text = "folded", .old_line = 9, .new_line = 9 }},
            },
            .{
                .header = "@@ -20 +20 @@",
                .old_start = 20,
                .old_count = 1,
                .new_start = 20,
                .new_count = 1,
                .section = "",
                .lines = &.{.{ .kind = .added, .text = "last", .new_line = 20 }},
            },
        },
    };
    const selection: DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .unified_diff,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 2, .line_index = 0 },
        .moved = true,
    };
    const text = try copyTextFolded(std.testing.allocator, file, &.{ false, true, false }, selection);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(" same\n-old\n+new\n+last\n", text);

    var owned = try buildUnifiedDiff(
        std.testing.allocator,
        file,
        &.{ false, true, false },
        selection.range(),
    );
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), owned.line_count);
    try std.testing.expectEqualSlices(Point, &.{
        .{ .hunk_index = 0, .line_index = 0 },
        .{ .hunk_index = 0, .line_index = 1 },
        .{ .hunk_index = 0, .line_index = 2 },
        .{ .hunk_index = 2, .line_index = 0 },
    }, owned.points);
}

test "semantic line distance counts selected side across holes and hunk boundaries" {
    const file: diff_parser.FileDiff = .{
        .header = "diff",
        .metadata = &.{},
        .hunks = &.{
            .{
                .old_start = 1,
                .old_count = 3,
                .new_start = 1,
                .new_count = 3,
                .section = "",
                .lines = &.{
                    .{ .kind = .context, .text = "one", .old_line = 1, .new_line = 1 },
                    .{ .kind = .removed, .text = "old", .old_line = 2 },
                    .{ .kind = .added, .text = "new", .new_line = 2 },
                    .{ .kind = .context, .text = "three", .old_line = 3, .new_line = 3 },
                },
            },
            .{
                .old_start = 20,
                .old_count = 1,
                .new_start = 20,
                .new_count = 1,
                .section = "",
                .lines = &.{.{ .kind = .context, .text = "twenty", .old_line = 20, .new_line = 20 }},
            },
        },
    };
    const first = pointFromLine(0, 0);
    const last = pointFromLine(1, 0);
    try std.testing.expectEqual(@as(?usize, 3), semanticLineDistance(file, .new, first, last));
    try std.testing.expectEqual(@as(?usize, 3), semanticLineDistance(file, .old, last, first));
    try std.testing.expectEqual(@as(?usize, 1), semanticLineDistance(file, .new, first, pointFromLine(0, 2)));
    try std.testing.expect(semanticLineDistance(file, .old, first, pointFromLine(0, 2)) == null);
}

test "character fragments copy exact forward and reverse multi-line bytes" {
    const file: diff_parser.FileDiff = .{
        .header = "diff",
        .old_path = "a/example",
        .new_path = "b/example",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 2,
            .new_start = 1,
            .new_count = 2,
            .section = "",
            .lines = &.{
                .{ .kind = .context, .text = "ABCDEFG", .old_line = 1, .new_line = 1 },
                .{ .kind = .context, .text = "HIJKLMN", .old_line = 2, .new_line = 2 },
            },
        }},
    };
    const identity: Identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "example" } };
    const forward = DragSelection{
        .identity = identity,
        .content = .{ .source_side = .{ .side = .new, .mode = .character } },
        .anchor = .{ .hunk_index = 0, .line_index = 0, .leading = 3, .trailing = 4 },
        .focus = .{ .hunk_index = 0, .line_index = 1, .leading = 4, .trailing = 5 },
        .moved = true,
    };
    const forward_text = try copyText(std.testing.allocator, file, forward);
    defer std.testing.allocator.free(forward_text);
    try std.testing.expectEqualStrings("DEFG\nHIJKL", forward_text);

    var reverse = forward;
    reverse.anchor = forward.focus;
    reverse.focus = forward.anchor;
    const reverse_text = try copyText(std.testing.allocator, file, reverse);
    defer std.testing.allocator.free(reverse_text);
    try std.testing.expectEqualStrings(forward_text, reverse_text);
}

test "character selection from the first token to its leading boundary keeps the token" {
    const cases = [_]struct {
        text: []const u8,
        token_end: usize,
        expected: []const u8,
    }{
        .{ .text = "ASCII", .token_end = 1, .expected = "A" },
        .{ .text = "e\u{301}rest", .token_end = 3, .expected = "e\u{301}" },
        .{ .text = "界rest", .token_end = 3, .expected = "界" },
        .{ .text = "\trest", .token_end = 1, .expected = "\t" },
    };

    for (cases) |case| {
        const lines = [_]diff_parser.DiffLine{.{
            .kind = .context,
            .text = case.text,
            .old_line = 1,
            .new_line = 1,
        }};
        const file: diff_parser.FileDiff = .{
            .header = "diff --git a/a b/a",
            .old_path = "a/a",
            .new_path = "b/a",
            .metadata = &.{},
            .hunks = &.{.{
                .old_start = 1,
                .old_count = 1,
                .new_start = 1,
                .new_count = 1,
                .section = "",
                .lines = &lines,
            }},
        };
        const selection: DragSelection = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .content = .{ .source_side = .{ .side = .new, .mode = .character } },
            .anchor = pointFromToken(0, 0, .{
                .byte_start = 0,
                .byte_end = case.token_end,
                .cell_start = 0,
                .cell_end = 1,
            }),
            .focus = pointFromBoundary(0, 0, 0),
            .moved = true,
        };

        const copied = try copyText(std.testing.allocator, file, selection);
        defer std.testing.allocator.free(copied);
        try std.testing.expectEqualStrings(case.expected, copied);
    }
}

test "cross-hunk character fragments use one glue LF and no trailing LF" {
    const file: diff_parser.FileDiff = .{
        .header = "diff",
        .metadata = &.{},
        .hunks = &.{
            .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .section = "", .lines = &.{.{ .kind = .context, .text = "abc", .old_line = 1, .new_line = 1 }} },
            .{ .old_start = 20, .old_count = 1, .new_start = 20, .new_count = 1, .section = "", .lines = &.{.{ .kind = .context, .text = "xyz", .old_line = 20, .new_line = 20 }} },
        },
    };
    const text = try copyText(std.testing.allocator, file, .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "example" } },
        .content = .{ .source_side = .{ .side = .new, .mode = .character } },
        .anchor = .{ .hunk_index = 0, .line_index = 0, .leading = 1, .trailing = 2 },
        .focus = .{ .hunk_index = 1, .line_index = 0, .leading = 1, .trailing = 2 },
        .moved = true,
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("bc\nxy", text);
}

test "copyText does not add trailing newline for one selected line" {
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{.{
            .old_start = 1,
            .old_count = 1,
            .new_start = 1,
            .new_count = 1,
            .section = "",
            .lines = &.{.{ .kind = .context, .text = "one", .old_line = 1, .new_line = 1 }},
        }},
    };

    const text = try copyText(std.testing.allocator, file, .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .{ .source_side = .{ .side = .new } },
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 0 },
        .moved = true,
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("one", text);
}
