//! Repository-local logical source selection and owned release candidates.
//!
//! Live points borrow only the accepted current-file basis. Terminal cells are
//! gesture input, never retained text coordinates: copied bytes are rebuilt
//! from strict UTF-8 grapheme boundaries in `repository/source.zig`. Release
//! candidates clone the byte-exact path and selected text so later source or
//! viewport replacement cannot retarget them.

const std = @import("std");
const content_fingerprint = @import("../../../content_fingerprint.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const source = @import("../../../repository/source.zig");
const text_projection = @import("chasen_ui").text_projection;

const Fingerprint = content_fingerprint.Fingerprint;
const repository_tab_width: usize = 4;

pub const Mode = enum {
    character,
    line,
};

pub const Origin = enum {
    mouse,
    keyboard_line,
};

pub const Point = struct {
    line_index: usize,
    /// Strict byte boundaries for character mode. Line mode ignores them.
    leading_byte: usize = 0,
    trailing_byte: usize = 0,

    /// The trailing boundary disambiguates a leading boundary `{0, 0}` from
    /// the first token `{0, token_end}`. Comparing only `leading_byte` would
    /// collapse a first-token-to-gutter drag into an empty range.
    pub fn beforeOrEqual(self: Point, other: Point) bool {
        return self.line_index < other.line_index or
            (self.line_index == other.line_index and
                (self.leading_byte < other.leading_byte or
                    (self.leading_byte == other.leading_byte and self.trailing_byte <= other.trailing_byte)));
    }
};

pub const Range = struct {
    start: Point,
    end: Point,
};

pub const Cell = struct {
    col: u16,
    row: u16,

    pub fn eql(self: Cell, other: Cell) bool {
        return self.col == other.col and self.row == other.row;
    }
};

/// Borrowed semantic identity of the accepted Repository current file.
/// Delivery generations and presentation state are deliberately absent.
pub const RepositoryContentToken = struct {
    repo_epoch: u64,
    root_identity: root_capability.Identity,
    path: []const u8,
    source_fingerprint: Fingerprint,

    pub fn eql(self: RepositoryContentToken, other: RepositoryContentToken) bool {
        return self.repo_epoch == other.repo_epoch and
            self.root_identity.eql(other.root_identity) and
            std.mem.eql(u8, self.path, other.path) and
            self.source_fingerprint.eql(other.source_fingerprint);
    }
};

pub const DragSelection = struct {
    token: RepositoryContentToken,
    mode: Mode,
    origin: Origin = .mouse,
    anchor: Point,
    focus: Point,
    anchor_cell: ?Cell = null,
    moved: bool = false,

    pub fn init(token: RepositoryContentToken, mode: Mode, point: Point) DragSelection {
        return .{
            .token = token,
            .mode = mode,
            .anchor = point,
            .focus = point,
        };
    }

    pub fn initKeyboardLine(token: RepositoryContentToken, line_index: usize) DragSelection {
        const point = pointFromLine(line_index);
        return .{
            .token = token,
            .mode = .line,
            .origin = .keyboard_line,
            .anchor = point,
            .focus = point,
        };
    }

    pub fn initAtCell(token: RepositoryContentToken, mode: Mode, point: Point, cell: Cell) DragSelection {
        return .{
            .token = token,
            .mode = mode,
            .anchor = point,
            .focus = point,
            .anchor_cell = cell,
        };
    }

    pub fn update(self: *DragSelection, point: Point) void {
        if (!pointEql(self.focus, point)) self.moved = true;
        self.focus = point;
    }

    pub fn updateAtCell(self: *DragSelection, point: Point, cell: Cell) void {
        if (self.anchor_cell) |anchor_cell| {
            if (!anchor_cell.eql(cell)) self.moved = true;
        } else if (!pointEql(self.focus, point)) {
            self.moved = true;
        }
        self.focus = point;
    }

    pub fn range(self: DragSelection) Range {
        if (self.anchor.beforeOrEqual(self.focus)) {
            return .{ .start = self.anchor, .end = self.focus };
        }
        return .{ .start = self.focus, .end = self.anchor };
    }

    pub fn lineCount(self: DragSelection) usize {
        const normalized = self.range();
        return normalized.end.line_index - normalized.start.line_index + 1;
    }
};

/// Borrowed identity of the selected path rendered in the Repository source
/// header. Unlike `RepositoryContentToken`, this identity needs no accepted
/// source bytes: loading, inert, and retained selected paths can all be copied.
/// `path` borrows the accepted manifest and the owner must be canceled before
/// that manifest is replaced or released.
pub const SourceHeaderIdentity = struct {
    repo_epoch: u64,
    activation_id: u64,
    root_identity: root_capability.Identity,
    manifest_revision: u64,
    path: []const u8,

    pub fn eql(self: SourceHeaderIdentity, other: SourceHeaderIdentity) bool {
        return self.repo_epoch == other.repo_epoch and
            self.activation_id == other.activation_id and
            self.root_identity.eql(other.root_identity) and
            self.manifest_revision == other.manifest_revision and
            std.mem.eql(u8, self.path, other.path);
    }
};

pub const SourceHeaderPathSelection = struct {
    identity: SourceHeaderIdentity,
};

/// Exclusive owner of a Repository live selection gesture.
///
pub const Owner = union(enum) {
    none,
    source: DragSelection,
    source_header: SourceHeaderPathSelection,

    pub fn activeSource(self: Owner) ?DragSelection {
        return switch (self) {
            .none, .source_header => null,
            .source => |selection| selection,
        };
    }

    pub fn activeMouseSource(self: Owner) ?DragSelection {
        const selection = self.activeSource() orelse return null;
        return if (selection.origin == .mouse) selection else null;
    }

    pub fn activeKeyboardLineSelection(self: Owner) ?DragSelection {
        const selection = self.activeSource() orelse return null;
        return if (selection.origin == .keyboard_line) selection else null;
    }

    pub fn activeSourceHeader(self: Owner) ?SourceHeaderPathSelection {
        return switch (self) {
            .none, .source => null,
            .source_header => |selection| selection,
        };
    }

    /// Whether any gesture owns pane-external drag/release routing and blocks
    /// a second press or wheel event from replacing the pointer stream.
    pub fn activeMouseOwner(self: Owner) bool {
        return switch (self) {
            .none => false,
            .source => |selection| selection.origin == .mouse,
            .source_header => true,
        };
    }

    /// Whether accepted source bytes are borrowed by a live range gesture.
    /// Page-transition blocking and later deferred source apply use only this
    /// narrower question, never the aggregate mouse-owner predicate.
    pub fn activeMouseSourceRange(self: Owner) bool {
        return switch (self) {
            .none, .source_header => false,
            .source => |selection| selection.origin == .mouse,
        };
    }

    pub fn activeBorrowedSourceRange(self: Owner) bool {
        return switch (self) {
            .none, .source_header => false,
            .source => true,
        };
    }
};

pub const OwnedContentToken = struct {
    repo_epoch: u64,
    root_identity: root_capability.Identity,
    path: []u8,
    source_fingerprint: Fingerprint,

    fn clone(allocator: std.mem.Allocator, token: RepositoryContentToken) !OwnedContentToken {
        return .{
            .repo_epoch = token.repo_epoch,
            .root_identity = token.root_identity,
            .path = try allocator.dupe(u8, token.path),
            .source_fingerprint = token.source_fingerprint,
        };
    }

    pub fn deinit(self: *OwnedContentToken, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }

    pub fn view(self: *const OwnedContentToken) RepositoryContentToken {
        return .{
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
            .path = self.path,
            .source_fingerprint = self.source_fingerprint,
        };
    }
};

pub const CompletedSelection = struct {
    token: OwnedContentToken,
    mode: Mode,
    range: Range,
    source_start: u32,
    source_end: u32,
    line_count: usize,
    text: []u8,

    pub fn deinit(self: *CompletedSelection, allocator: std.mem.Allocator) void {
        self.token.deinit(allocator);
        allocator.free(self.text);
        self.* = undefined;
    }

    /// Clipboard delivery receives a separate owner. A later delivery failure
    /// must not invalidate the accepted page-owned candidate.
    pub fn clipboardText(self: *const CompletedSelection, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, self.text);
    }

    /// Admit the retained candidate only against the exact current content
    /// token and a range which is still meaningful for those source bytes.
    /// Delivery generations and screen coordinates are intentionally absent.
    pub fn isAdmitted(
        self: *const CompletedSelection,
        document: *const source.Document,
        token: RepositoryContentToken,
    ) bool {
        if (!self.token.view().eql(token) or
            !self.token.source_fingerprint.eql(document.fingerprint))
        {
            return false;
        }
        const content_lines = document.contentLineCount();
        if (content_lines == 0 or
            self.range.start.line_index >= content_lines or
            self.range.end.line_index >= content_lines or
            !self.range.start.beforeOrEqual(self.range.end))
        {
            return false;
        }
        const expected_line_count = self.range.end.line_index - self.range.start.line_index + 1;
        if (self.line_count != expected_line_count or
            @as(usize, self.source_start) != self.range.start.line_index + 1 or
            @as(usize, self.source_end) != self.range.end.line_index + 1 or
            (self.mode == .character and self.text.len == 0))
        {
            return false;
        }
        return switch (self.mode) {
            .line => true,
            .character => validCharacterPoint(document, self.range.start) and
                validCharacterPoint(document, self.range.end),
        };
    }
};

pub const BuildError = error{
    NotMoved,
    StaleContent,
    InvalidSelection,
    EmptySelection,
    OutOfMemory,
};

pub fn pointFromLine(line_index: usize) Point {
    return .{ .line_index = line_index };
}

pub fn pointFromToken(line_index: usize, token: text_projection.Token) Point {
    return .{
        .line_index = line_index,
        .leading_byte = token.byte_start,
        .trailing_byte = token.byte_end,
    };
}

pub fn pointFromBoundary(line_index: usize, byte_offset: usize) Point {
    return .{
        .line_index = line_index,
        .leading_byte = byte_offset,
        .trailing_byte = byte_offset,
    };
}

pub fn buildCompletedSelection(
    allocator: std.mem.Allocator,
    document: *const source.Document,
    selection: DragSelection,
) BuildError!CompletedSelection {
    if (!selection.moved and selection.origin == .mouse) return error.NotMoved;
    if (!selection.token.source_fingerprint.eql(document.fingerprint)) return error.StaleContent;

    const range = selection.range();
    const content_line_count = document.contentLineCount();
    if (content_line_count == 0 or range.start.line_index >= content_line_count or
        range.end.line_index >= content_line_count)
    {
        return error.InvalidSelection;
    }
    if (selection.mode == .character and
        (!validCharacterPoint(document, range.start) or !validCharacterPoint(document, range.end)))
    {
        return error.InvalidSelection;
    }

    const line_count = selection.lineCount();
    var text_len: usize = 0;
    var line_index = range.start.line_index;
    while (line_index <= range.end.line_index) : (line_index += 1) {
        const line = document.lineBody(line_index) orelse return error.InvalidSelection;
        const bytes = try selectedBytesForLine(line, selection.mode, range, line_index);
        if (line_index > range.start.line_index) text_len = checkedAdd(text_len, 1) orelse return error.InvalidSelection;
        text_len = checkedAdd(text_len, bytes.len) orelse return error.InvalidSelection;
    }
    if (selection.mode == .line and line_count >= 2) {
        text_len = checkedAdd(text_len, 1) orelse return error.InvalidSelection;
    }
    if (selection.mode == .character and text_len == 0) return error.EmptySelection;

    const text = try allocator.alloc(u8, text_len);
    errdefer allocator.free(text);
    var cursor: usize = 0;
    line_index = range.start.line_index;
    while (line_index <= range.end.line_index) : (line_index += 1) {
        const line = document.lineBody(line_index) orelse return error.InvalidSelection;
        const bytes = try selectedBytesForLine(line, selection.mode, range, line_index);
        if (line_index > range.start.line_index) {
            text[cursor] = '\n';
            cursor += 1;
        }
        @memcpy(text[cursor .. cursor + bytes.len], bytes);
        cursor += bytes.len;
    }
    if (selection.mode == .line and line_count >= 2) {
        text[cursor] = '\n';
        cursor += 1;
    }
    std.debug.assert(cursor == text.len);

    var token = try OwnedContentToken.clone(allocator, selection.token);
    errdefer token.deinit(allocator);
    return .{
        .token = token,
        .mode = selection.mode,
        .range = range,
        .source_start = @intCast(range.start.line_index + 1),
        .source_end = @intCast(range.end.line_index + 1),
        .line_count = line_count,
        .text = text,
    };
}

fn selectedBytesForLine(line: []const u8, mode: Mode, range: Range, line_index: usize) BuildError![]const u8 {
    if (mode == .line) return line;
    const start = if (line_index == range.start.line_index) range.start.leading_byte else 0;
    const end = if (line_index == range.end.line_index) range.end.trailing_byte else line.len;
    const projection = text_projection.Projection.init(line, .{ .tab_width = repository_tab_width }) catch
        return error.InvalidSelection;
    if (start > end or !projection.isBoundary(start) or !projection.isBoundary(end)) {
        return error.InvalidSelection;
    }
    return line[start..end];
}

/// Every retained byte in a character point is a strict boundary, including
/// the side not used directly for first/last-line extraction. The completed
/// range may later feed rendering or a durable snapshot, so validation cannot
/// be deferred to whichever endpoint the current assembler happens to slice.
fn validCharacterPoint(document: *const source.Document, point: Point) bool {
    const line = document.lineBody(point.line_index) orelse return false;
    const projection = text_projection.Projection.init(line, .{ .tab_width = repository_tab_width }) catch return false;
    return point.leading_byte <= point.trailing_byte and
        projection.isBoundary(point.leading_byte) and
        projection.isBoundary(point.trailing_byte);
}

fn pointEql(left: Point, right: Point) bool {
    return left.line_index == right.line_index and
        left.leading_byte == right.leading_byte and
        left.trailing_byte == right.trailing_byte;
}

fn checkedAdd(left: usize, right: usize) ?usize {
    return std.math.add(usize, left, right) catch null;
}

fn testToken(path: []const u8, bytes: []const u8) RepositoryContentToken {
    return .{
        .repo_epoch = 7,
        .root_identity = .{ .device = 11, .inode = 13 },
        .path = path,
        .source_fingerprint = Fingerprint.init(bytes),
    };
}

test "repository selection owner keeps pointer and source-range predicates explicit" {
    var owner: Owner = .none;
    try std.testing.expect(!owner.activeMouseOwner());
    try std.testing.expect(!owner.activeMouseSourceRange());
    try std.testing.expect(!owner.activeBorrowedSourceRange());
    try std.testing.expect(owner.activeSource() == null);

    owner = .{ .source = DragSelection.init(
        testToken("main.zig", "source"),
        .character,
        pointFromBoundary(0, 0),
    ) };
    try std.testing.expect(owner.activeMouseOwner());
    try std.testing.expect(owner.activeMouseSourceRange());
    try std.testing.expect(owner.activeBorrowedSourceRange());
    try std.testing.expect(owner.activeSource() != null);

    owner = .{ .source = DragSelection.initKeyboardLine(
        testToken("main.zig", "source"),
        2,
    ) };
    try std.testing.expect(!owner.activeMouseOwner());
    try std.testing.expect(!owner.activeMouseSourceRange());
    try std.testing.expect(owner.activeBorrowedSourceRange());
    try std.testing.expectEqual(@as(usize, 1), owner.activeKeyboardLineSelection().?.lineCount());

    owner = .none;
    try std.testing.expect(!owner.activeMouseOwner());
    try std.testing.expect(!owner.activeMouseSourceRange());
    try std.testing.expect(!owner.activeBorrowedSourceRange());
}

test "repository keyboard line selection completes one exact line without mouse movement" {
    const bytes = "alpha\nbeta\ngamma";
    var document = try testDocument(bytes);
    defer document.deinit(std.testing.allocator);
    const live = DragSelection.initKeyboardLine(testToken("src/example.zig", bytes), 1);

    try std.testing.expect(!live.moved);
    try std.testing.expectEqual(@as(usize, 1), live.lineCount());
    var completed = try buildCompletedSelection(std.testing.allocator, &document, live);
    defer completed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("beta", completed.text);
    try std.testing.expectEqual(@as(usize, 1), completed.line_count);
    try std.testing.expectEqual(@as(u32, 2), completed.source_start);
    try std.testing.expectEqual(@as(u32, 2), completed.source_end);
}

fn testDocument(bytes: []const u8) !source.Document {
    const owned = try std.testing.allocator.dupe(u8, bytes);
    errdefer std.testing.allocator.free(owned);
    return source.Document.initOwned(std.testing.allocator, owned, Fingerprint.init(owned));
}

fn testSelection(token: RepositoryContentToken, mode: Mode, anchor: Point, focus: Point) DragSelection {
    return .{
        .token = token,
        .mode = mode,
        .anchor = anchor,
        .focus = focus,
        .moved = true,
    };
}

test "repository selection content token uses only semantic current file identity" {
    const base = testToken("src/main.zig", "source");
    try std.testing.expect(base.eql(base));

    var changed = base;
    changed.repo_epoch += 1;
    try std.testing.expect(!base.eql(changed));
    changed = base;
    changed.root_identity.inode += 1;
    try std.testing.expect(!base.eql(changed));
    changed = base;
    changed.path = "src/other.zig";
    try std.testing.expect(!base.eql(changed));
    changed = base;
    changed.source_fingerprint = Fingerprint.init("changed");
    try std.testing.expect(!base.eql(changed));
}

test "repository selection copies exact forward and reverse multiline text" {
    const bytes = "ABCDEFG\nHIJKLMN";
    var document = try testDocument(bytes);
    defer document.deinit(std.testing.allocator);
    const token = testToken("src/example.zig", bytes);
    const forward = testSelection(
        token,
        .character,
        .{ .line_index = 0, .leading_byte = 3, .trailing_byte = 4 },
        .{ .line_index = 1, .leading_byte = 4, .trailing_byte = 5 },
    );
    var completed = try buildCompletedSelection(std.testing.allocator, &document, forward);
    defer completed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("DEFG\nHIJKL", completed.text);
    try std.testing.expectEqual(@as(u32, 1), completed.source_start);
    try std.testing.expectEqual(@as(u32, 2), completed.source_end);
    try std.testing.expect(completed.isAdmitted(&document, token));
    completed.line_count += 1;
    try std.testing.expect(!completed.isAdmitted(&document, token));
    completed.line_count -= 1;

    var reverse = forward;
    reverse.anchor = forward.focus;
    reverse.focus = forward.anchor;
    var reversed = try buildCompletedSelection(std.testing.allocator, &document, reverse);
    defer reversed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(completed.text, reversed.text);
}

test "repository selection point total order keeps first tokens dragged to their own gutter" {
    const cases = [_]struct { line: []const u8, expected: []const u8 }{
        .{ .line = "ASCII", .expected = "A" },
        .{ .line = "\trest", .expected = "\t" },
        .{ .line = "界rest", .expected = "界" },
        .{ .line = "e\u{301}rest", .expected = "e\u{301}" },
    };
    for (cases) |case| {
        var document = try testDocument(case.line);
        defer document.deinit(std.testing.allocator);
        const token = testToken("first-token.zig", case.line);
        const projection = try text_projection.Projection.init(case.line, .{ .tab_width = repository_tab_width });
        const first = switch (projection.hitCell(0)) {
            .token => |value| value,
            .boundary => return error.ExpectedToken,
        };
        const token_point = pointFromToken(0, first);
        const gutter = pointFromBoundary(0, 0);
        try std.testing.expect(gutter.beforeOrEqual(token_point));
        try std.testing.expect(!token_point.beforeOrEqual(gutter));

        const directions = [_][2]Point{
            .{ token_point, gutter },
            .{ gutter, token_point },
        };
        for (directions) |direction| {
            var completed = try buildCompletedSelection(
                std.testing.allocator,
                &document,
                testSelection(token, .character, direction[0], direction[1]),
            );
            defer completed.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(case.expected, completed.text);
        }
    }
}

test "repository selection character assembler preserves empty lines and normalizes source newlines" {
    const cases = [_]struct { bytes: []const u8, expected: []const u8 }{
        .{ .bytes = "a\n\nb", .expected = "a\n\nb" },
        .{ .bytes = "a\r\n\r\nb", .expected = "a\n\nb" },
        .{ .bytes = "a\nb\n", .expected = "a\nb" },
    };
    for (cases) |case| {
        var document = try testDocument(case.bytes);
        defer document.deinit(std.testing.allocator);
        const last_line = document.contentLineCount() - 1;
        const last = document.lineBody(last_line).?;
        var completed = try buildCompletedSelection(
            std.testing.allocator,
            &document,
            testSelection(
                testToken("newline.zig", case.bytes),
                .character,
                pointFromBoundary(0, 0),
                pointFromBoundary(last_line, last.len),
            ),
        );
        defer completed.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, completed.text);
    }
}

test "repository selection line assembler applies single and multiline newline policy" {
    const bytes = "one\n\nthree";
    var document = try testDocument(bytes);
    defer document.deinit(std.testing.allocator);
    const token = testToken("lines.zig", bytes);

    var one = try buildCompletedSelection(
        std.testing.allocator,
        &document,
        testSelection(token, .line, pointFromLine(0), pointFromLine(0)),
    );
    defer one.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("one", one.text);

    var empty = try buildCompletedSelection(
        std.testing.allocator,
        &document,
        testSelection(token, .line, pointFromLine(1), pointFromLine(1)),
    );
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", empty.text);

    var multiple = try buildCompletedSelection(
        std.testing.allocator,
        &document,
        testSelection(token, .line, pointFromLine(0), pointFromLine(2)),
    );
    defer multiple.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("one\n\nthree\n", multiple.text);
}

test "repository selection character assembler preserves atomic TAB combining emoji and wide tokens" {
    const line = "\te\u{301}👩‍💻界";
    var document = try testDocument(line);
    defer document.deinit(std.testing.allocator);
    const token = testToken("unicode.zig", line);
    var display_cell: usize = 0;
    const projection = try text_projection.Projection.init(line, .{ .tab_width = repository_tab_width });
    const expected = [_][]const u8{ "\t", "e\u{301}", "👩‍💻", "界" };
    for (expected) |wanted| {
        const hit = switch (projection.hitCell(display_cell)) {
            .token => |value| value,
            .boundary => return error.ExpectedToken,
        };
        var completed = try buildCompletedSelection(
            std.testing.allocator,
            &document,
            testSelection(token, .character, pointFromToken(0, hit), pointFromBoundary(0, hit.byte_end)),
        );
        defer completed.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(wanted, completed.text);
        display_cell = hit.cell_end;
    }
}

test "repository selection rejects invalid or stale coordinates" {
    const bytes = "e\u{301}x";
    var document = try testDocument(bytes);
    defer document.deinit(std.testing.allocator);
    const token = testToken("invalid.zig", bytes);

    try std.testing.expectError(error.NotMoved, buildCompletedSelection(std.testing.allocator, &document, .{
        .token = token,
        .mode = .character,
        .anchor = pointFromBoundary(0, 0),
        .focus = pointFromBoundary(0, bytes.len),
    }));
    try std.testing.expectError(error.InvalidSelection, buildCompletedSelection(
        std.testing.allocator,
        &document,
        testSelection(token, .character, pointFromBoundary(0, 1), pointFromBoundary(0, bytes.len)),
    ));
    try std.testing.expectError(error.InvalidSelection, buildCompletedSelection(
        std.testing.allocator,
        &document,
        testSelection(
            token,
            .character,
            .{ .line_index = 0, .leading_byte = 0, .trailing_byte = 1 },
            pointFromBoundary(0, bytes.len),
        ),
    ));
    try std.testing.expectError(error.InvalidSelection, buildCompletedSelection(
        std.testing.allocator,
        &document,
        testSelection(
            token,
            .character,
            pointFromBoundary(0, 0),
            .{ .line_index = 0, .leading_byte = 1, .trailing_byte = bytes.len },
        ),
    ));
    try std.testing.expectError(error.InvalidSelection, buildCompletedSelection(
        std.testing.allocator,
        &document,
        testSelection(
            token,
            .character,
            .{ .line_index = 0, .leading_byte = 3, .trailing_byte = 0 },
            pointFromBoundary(0, bytes.len),
        ),
    ));
    try std.testing.expectError(error.InvalidSelection, buildCompletedSelection(
        std.testing.allocator,
        &document,
        testSelection(token, .line, pointFromLine(0), pointFromLine(1)),
    ));
    var stale = token;
    stale.source_fingerprint = Fingerprint.init("other");
    try std.testing.expectError(error.StaleContent, buildCompletedSelection(
        std.testing.allocator,
        &document,
        testSelection(stale, .line, pointFromLine(0), pointFromLine(0)),
    ));

    var empty_document = try testDocument("");
    defer empty_document.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidSelection, buildCompletedSelection(
        std.testing.allocator,
        &empty_document,
        testSelection(testToken("empty.zig", ""), .line, pointFromLine(0), pointFromLine(0)),
    ));
}

test "repository selection owns raw path text and clipboard bytes" {
    const allocator = std.testing.allocator;
    const bytes = "selected";
    var document = try testDocument(bytes);
    defer document.deinit(allocator);
    var raw_path = [_]u8{ 's', 'r', 'c', '/', 0xff, '.', 'z', 'i', 'g' };
    const original = raw_path;
    var completed = try buildCompletedSelection(
        allocator,
        &document,
        testSelection(testToken(&raw_path, bytes), .line, pointFromLine(0), pointFromLine(0)),
    );
    defer completed.deinit(allocator);
    raw_path[0] = 'X';
    try std.testing.expectEqualSlices(u8, &original, completed.token.path);

    const clipboard = try completed.clipboardText(allocator);
    defer allocator.free(clipboard);
    clipboard[0] = 'S';
    try std.testing.expectEqualStrings("selected", completed.text);
}

test "repository selection releases every partial allocation" {
    const bytes = "first\nsecond";
    var document = try testDocument(bytes);
    defer document.deinit(std.testing.allocator);
    const selection = testSelection(
        testToken("allocation.zig", bytes),
        .character,
        pointFromBoundary(0, 1),
        pointFromBoundary(1, 3),
    );
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn build(allocator: std.mem.Allocator, doc: *const source.Document, drag: DragSelection) !void {
            var completed = try buildCompletedSelection(allocator, doc, drag);
            defer completed.deinit(allocator);
        }
    }.build, .{ &document, selection });
}

test "repository source header identity and owner predicates stay policy-specific" {
    const base: SourceHeaderIdentity = .{
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = .{ .device = 5, .inode = 6 },
        .manifest_revision = 7,
        .path = "src/main.zig",
    };
    try std.testing.expect(base.eql(base));
    inline for (.{
        SourceHeaderIdentity{ .repo_epoch = 30, .activation_id = 4, .root_identity = .{ .device = 5, .inode = 6 }, .manifest_revision = 7, .path = "src/main.zig" },
        SourceHeaderIdentity{ .repo_epoch = 3, .activation_id = 40, .root_identity = .{ .device = 5, .inode = 6 }, .manifest_revision = 7, .path = "src/main.zig" },
        SourceHeaderIdentity{ .repo_epoch = 3, .activation_id = 4, .root_identity = .{ .device = 50, .inode = 6 }, .manifest_revision = 7, .path = "src/main.zig" },
        SourceHeaderIdentity{ .repo_epoch = 3, .activation_id = 4, .root_identity = .{ .device = 5, .inode = 6 }, .manifest_revision = 70, .path = "src/main.zig" },
        SourceHeaderIdentity{ .repo_epoch = 3, .activation_id = 4, .root_identity = .{ .device = 5, .inode = 6 }, .manifest_revision = 7, .path = "src/other.zig" },
    }) |different| try std.testing.expect(!base.eql(different));

    const header_owner: Owner = .{ .source_header = .{ .identity = base } };
    try std.testing.expect(header_owner.activeMouseOwner());
    try std.testing.expect(!header_owner.activeMouseSourceRange());
    try std.testing.expect(header_owner.activeSource() == null);
    try std.testing.expect(header_owner.activeSourceHeader().?.identity.eql(base));

    const source_owner: Owner = .{ .source = DragSelection.init(
        testToken("src/main.zig", "source"),
        .character,
        pointFromBoundary(0, 0),
    ) };
    try std.testing.expect(source_owner.activeMouseOwner());
    try std.testing.expect(source_owner.activeMouseSourceRange());
    try std.testing.expect(source_owner.activeSourceHeader() == null);
}
