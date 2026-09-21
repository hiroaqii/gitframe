//! Owned Changes selection candidates and their stable content basis.
//!
//! Live drag coordinates borrow the currently displayed model. Release must
//! convert them transactionally into this module's owned paths, fragments, and
//! semantic token before any deferred source/projection replacement may free
//! that model. Clipboard bytes are assembled as a separate owner afterwards.

const std = @import("std");
const content_fingerprint = @import("../../content_fingerprint.zig");
const diff_file = @import("../../diff/file.zig");
const diff_parser = @import("../../diff/parser.zig");
const diff_presentation_identity = @import("../../diff/presentation_identity.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_source = @import("../../diff/source.zig");
const path_key = @import("../../path_key.zig");
const repository_source = @import("../../repository/source.zig");
const root_capability = @import("../../repo/root_capability.zig");
const text_projection = @import("chasen_ui").text_projection;

const Fingerprint = content_fingerprint.Fingerprint;
const review_tab_width: usize = 4;

pub const SourceBasis = struct {
    kind: std.meta.Tag(diff_source.SourceMode),
    parameter_a: Fingerprint,
    parameter_b: Fingerprint,

    pub fn init(source: diff_source.SourceMode) SourceBasis {
        const empty = Fingerprint.init("");
        return switch (source) {
            .unstaged => .{ .kind = .unstaged, .parameter_a = empty, .parameter_b = empty },
            .cached => .{ .kind = .cached, .parameter_a = empty, .parameter_b = empty },
            .stdin => .{ .kind = .stdin, .parameter_a = empty, .parameter_b = empty },
            .pager => |value| .{ .kind = .pager, .parameter_a = Fingerprint.init(value), .parameter_b = empty },
            .patch_file => |value| .{ .kind = .patch_file, .parameter_a = Fingerprint.init(value), .parameter_b = empty },
            .range => |value| .{ .kind = .range, .parameter_a = Fingerprint.init(value), .parameter_b = empty },
            .no_index => |paths| .{ .kind = .no_index, .parameter_a = Fingerprint.init(paths.left), .parameter_b = Fingerprint.init(paths.right) },
        };
    }

    pub fn eql(self: SourceBasis, other: SourceBasis) bool {
        return self.kind == other.kind and self.parameter_a.eql(other.parameter_a) and self.parameter_b.eql(other.parameter_b);
    }
};

pub const DisplayBasis = union(enum) {
    loaded: Fingerprint,
    cached_projection: struct { status_snapshot_revision: u64, cached: Fingerprint },
    combined_projection: diff_presentation_identity.ContentToken,
    generated_untracked: struct { status_snapshot_revision: u64, source: Fingerprint },

    pub fn eql(self: DisplayBasis, other: DisplayBasis) bool {
        return switch (self) {
            .loaded => |fingerprint| switch (other) {
                .loaded => |other_fingerprint| fingerprint.eql(other_fingerprint),
                else => false,
            },
            .cached_projection => |basis| switch (other) {
                .cached_projection => |other_basis| basis.status_snapshot_revision == other_basis.status_snapshot_revision and basis.cached.eql(other_basis.cached),
                else => false,
            },
            .combined_projection => |token| switch (other) {
                .combined_projection => |other_token| token.eql(other_token),
                else => false,
            },
            .generated_untracked => |basis| switch (other) {
                .generated_untracked => |other_basis| basis.status_snapshot_revision == other_basis.status_snapshot_revision and basis.source.eql(other_basis.source),
                else => false,
            },
        };
    }
};

pub const ContentToken = struct {
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,
    source: SourceBasis,
    source_session_revision: u64,
    display: DisplayBasis,

    pub fn eql(self: ContentToken, other: ContentToken) bool {
        return self.repo_epoch == other.repo_epoch and
            optionalRootIdentityEql(self.root_identity, other.root_identity) and
            self.source.eql(other.source) and
            self.source_session_revision == other.source_session_revision and
            self.display.eql(other.display);
    }
};

pub const Parsed = struct {
    canonical_path: []u8,
    old_path: ?[]u8,
    new_path: ?[]u8,
    range: diff_selection.Range,
    content: union(enum) {
        source_side: SourceSide,
        unified_diff: diff_selection.OwnedUnifiedDiff,

        pub const SourceSide = struct {
            selected_path: []u8,
            side: diff_selection.Side,
            mode: diff_selection.Mode,
            fragments: diff_selection.OwnedFragments,

            fn deinit(self: *SourceSide, allocator: std.mem.Allocator) void {
                allocator.free(self.selected_path);
                self.fragments.deinit(allocator);
                self.* = undefined;
            }
        };
    },

    fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_path);
        if (self.old_path) |path| allocator.free(path);
        if (self.new_path) |path| allocator.free(path);
        switch (self.content) {
            .source_side => |*source| source.deinit(allocator),
            .unified_diff => |*unified| unified.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const GeneratedFragment = struct {
    source_start: u32,
    source_end: u32,
    text: []u8,
    line_count: usize,

    fn deinit(self: *GeneratedFragment, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Generated = struct {
    path: []u8,
    range: diff_selection.Range,
    content: union(enum) {
        source_side: SourceSide,
        unified_diff: diff_selection.OwnedUnifiedDiff,

        pub const SourceSide = struct {
            mode: diff_selection.Mode,
            fragment: GeneratedFragment,

            fn deinit(self: *SourceSide, allocator: std.mem.Allocator) void {
                self.fragment.deinit(allocator);
                self.* = undefined;
            }
        };
    },

    fn deinit(self: *Generated, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        switch (self.content) {
            .source_side => |*source| source.deinit(allocator),
            .unified_diff => |*unified| unified.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const CompletedSelection = struct {
    token: ContentToken,
    selection_layout_revision: u64 = 0,
    value: union(enum) {
        parsed_diff: Parsed,
        generated_untracked: Generated,
    },

    pub fn deinit(self: *CompletedSelection, allocator: std.mem.Allocator) void {
        switch (self.value) {
            .parsed_diff => |*parsed| parsed.deinit(allocator),
            .generated_untracked => |*generated| generated.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn pathKey(self: CompletedSelection) []const u8 {
        return switch (self.value) {
            .parsed_diff => |parsed| parsed.canonical_path,
            .generated_untracked => |generated| generated.path,
        };
    }

    pub fn lineCount(self: CompletedSelection) usize {
        return switch (self.value) {
            .parsed_diff => |parsed| switch (parsed.content) {
                .source_side => |source| source.fragments.line_count,
                .unified_diff => |unified| unified.line_count,
            },
            .generated_untracked => |generated| switch (generated.content) {
                .source_side => |source| source.fragment.line_count,
                .unified_diff => |unified| unified.line_count,
            },
        };
    }

    pub fn clipboardText(self: CompletedSelection, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.value) {
            .parsed_diff => |parsed| switch (parsed.content) {
                .source_side => |source| source.fragments.clipboardText(allocator),
                .unified_diff => |unified| unified.clipboardText(allocator),
            },
            .generated_untracked => |generated| switch (generated.content) {
                .source_side => |source| blk: {
                    if (source.mode != .line or source.fragment.line_count < 2) {
                        break :blk allocator.dupe(u8, source.fragment.text);
                    }
                    const text = try allocator.alloc(u8, source.fragment.text.len + 1);
                    @memcpy(text[0..source.fragment.text.len], source.fragment.text);
                    text[text.len - 1] = '\n';
                    break :blk text;
                },
                .unified_diff => |unified| unified.clipboardText(allocator),
            },
        };
    }
};

pub fn buildParsed(
    allocator: std.mem.Allocator,
    token: ContentToken,
    file: diff_parser.FileDiff,
    selection: diff_selection.DragSelection,
) !CompletedSelection {
    return buildParsedFolded(allocator, token, file, &.{}, 1, selection);
}

pub fn buildParsedFolded(
    allocator: std.mem.Allocator,
    token: ContentToken,
    file: diff_parser.FileDiff,
    folded_hunks: []const bool,
    selection_layout_revision: u64,
    selection: diff_selection.DragSelection,
) !CompletedSelection {
    const canonical = diff_file.canonicalPathKey(file) orelse return error.NoPath;
    const old_path = normalizedOptionalPath(file.old_path);
    const new_path = normalizedOptionalPath(file.new_path);
    const canonical_owned = try allocator.dupe(u8, canonical);
    errdefer allocator.free(canonical_owned);
    const old_owned = try dupeOptional(allocator, old_path);
    errdefer if (old_owned) |path| allocator.free(path);
    const new_owned = try dupeOptional(allocator, new_path);
    errdefer if (new_owned) |path| allocator.free(path);
    var content: @FieldType(Parsed, "content") = switch (selection.content) {
        .source_side => |source| blk: {
            var fragments = try diff_selection.buildFragments(allocator, file, selection);
            errdefer fragments.deinit(allocator);
            if (fragments.items.len == 0) return error.EmptySelection;
            const selected_borrowed = switch (source.side) {
                .old => old_path,
                .new => new_path,
            } orelse return error.NoSelectedSidePath;
            const selected_owned = try allocator.dupe(u8, selected_borrowed);
            break :blk .{ .source_side = .{
                .selected_path = selected_owned,
                .side = source.side,
                .mode = source.mode,
                .fragments = fragments,
            } };
        },
        .unified_diff => blk: {
            const unified = try diff_selection.buildUnifiedDiff(allocator, file, folded_hunks, selection.range());
            if (unified.line_count == 0) {
                var empty = unified;
                empty.deinit(allocator);
                return error.EmptySelection;
            }
            break :blk .{ .unified_diff = unified };
        },
    };
    errdefer switch (content) {
        .source_side => |*source| source.deinit(allocator),
        .unified_diff => |*unified| unified.deinit(allocator),
    };

    return .{
        .token = token,
        .selection_layout_revision = selection_layout_revision,
        .value = .{ .parsed_diff = .{
            .canonical_path = canonical_owned,
            .old_path = old_owned,
            .new_path = new_owned,
            .range = selection.range(),
            .content = content,
        } },
    };
}

pub fn buildGenerated(
    allocator: std.mem.Allocator,
    token: ContentToken,
    path: []const u8,
    document: *const repository_source.Document,
    selection: diff_selection.DragSelection,
) !CompletedSelection {
    return buildGeneratedForLayout(allocator, token, path, document, 1, selection);
}

pub fn buildGeneratedForLayout(
    allocator: std.mem.Allocator,
    token: ContentToken,
    path: []const u8,
    document: *const repository_source.Document,
    selection_layout_revision: u64,
    selection: diff_selection.DragSelection,
) !CompletedSelection {
    const range = selection.range();
    if (range.start.hunk_index != 0 or range.end.hunk_index != 0 or range.start.line_index >= document.rowCount() or range.end.line_index >= document.rowCount()) return error.InvalidSelection;

    var content: @FieldType(Generated, "content") = switch (selection.content) {
        .source_side => |source| blk: {
            if (source.side != .new) return error.InvalidSide;
            break :blk .{ .source_side = .{
                .mode = source.mode,
                .fragment = try buildGeneratedFragment(allocator, document, range, source.mode),
            } };
        },
        .unified_diff => .{ .unified_diff = try buildGeneratedUnified(allocator, document, range) },
    };
    errdefer switch (content) {
        .source_side => |*source| source.deinit(allocator),
        .unified_diff => |*unified| unified.deinit(allocator),
    };
    const owned_path = try allocator.dupe(u8, path);
    return .{
        .token = token,
        .selection_layout_revision = selection_layout_revision,
        .value = .{ .generated_untracked = .{
            .path = owned_path,
            .range = range,
            .content = content,
        } },
    };
}

fn buildGeneratedFragment(
    allocator: std.mem.Allocator,
    document: *const repository_source.Document,
    range: diff_selection.Range,
    mode: diff_selection.Mode,
) !GeneratedFragment {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var line_count: usize = 0;
    var line_index = range.start.line_index;
    while (line_index <= range.end.line_index) : (line_index += 1) {
        const line = document.lineBody(line_index) orelse return error.InvalidSelection;
        var start: usize = 0;
        var end: usize = line.len;
        if (mode == .character) {
            if (line_index == range.start.line_index) start = range.start.leading;
            if (line_index == range.end.line_index) end = range.end.trailing;
            if (start > end) return error.InvalidSelection;
            const projection = text_projection.Projection.init(line, .{ .tab_width = review_tab_width }) catch return error.InvalidSelection;
            if (!projection.isBoundary(start) or !projection.isBoundary(end)) return error.InvalidSelection;
        }
        if (start == end and range.start.line_index == range.end.line_index) continue;
        if (line_count > 0) out.writer.writeByte('\n') catch return error.OutOfMemory;
        out.writer.writeAll(line[start..end]) catch return error.OutOfMemory;
        line_count += 1;
    }
    if (line_count == 0) return error.EmptySelection;
    const text = try out.toOwnedSlice();
    return .{
        .source_start = @intCast(range.start.line_index + 1),
        .source_end = @intCast(range.end.line_index + 1),
        .text = text,
        .line_count = line_count,
    };
}

fn buildGeneratedUnified(
    allocator: std.mem.Allocator,
    document: *const repository_source.Document,
    range: diff_selection.Range,
) !diff_selection.OwnedUnifiedDiff {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var points: std.ArrayList(diff_selection.Point) = .empty;
    errdefer points.deinit(allocator);

    var line_index = range.start.line_index;
    while (line_index <= range.end.line_index) : (line_index += 1) {
        const line = document.lineBody(line_index) orelse return error.InvalidSelection;
        if (points.items.len > 0) try out.writer.writeByte('\n');
        try out.writer.writeByte('+');
        try out.writer.writeAll(line);
        try points.append(allocator, diff_selection.pointFromLine(0, line_index));
    }
    if (points.items.len >= 2) try out.writer.writeByte('\n');
    const text = try out.toOwnedSlice();
    errdefer allocator.free(text);
    const owned_points = try points.toOwnedSlice(allocator);
    return .{ .text = text, .points = owned_points, .line_count = owned_points.len };
}

fn normalizedOptionalPath(path: ?[]const u8) ?[]const u8 {
    const value = path orelse return null;
    if (std.mem.eql(u8, value, "/dev/null")) return null;
    return path_key.stripGitSidePrefix(value);
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |bytes| try allocator.dupe(u8, bytes) else null;
}

fn optionalRootIdentityEql(left: ?root_capability.Identity, right: ?root_capability.Identity) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.eql(right.?);
}

test "content token ignores delivery identity by construction and separates source parameters" {
    const base = ContentToken{
        .repo_epoch = 3,
        .root_identity = .{ .device = 1, .inode = 2 },
        .source = SourceBasis.init(.{ .range = "main...HEAD" }),
        .source_session_revision = 7,
        .display = .{ .loaded = Fingerprint.init("diff") },
    };
    try std.testing.expect(base.eql(base));
    var changed = base;
    changed.source = SourceBasis.init(.{ .range = "HEAD~1...HEAD" });
    try std.testing.expect(!base.eql(changed));

    changed = base;
    changed.repo_epoch += 1;
    try std.testing.expect(!base.eql(changed));
    changed = base;
    changed.root_identity = .{ .device = 1, .inode = 3 };
    try std.testing.expect(!base.eql(changed));
    changed = base;
    changed.source_session_revision += 1;
    try std.testing.expect(!base.eql(changed));
    changed = base;
    changed.display = .{ .loaded = Fingerprint.init("other diff") };
    try std.testing.expect(!base.eql(changed));

    const cached = ContentToken{
        .repo_epoch = base.repo_epoch,
        .root_identity = base.root_identity,
        .source = base.source,
        .source_session_revision = base.source_session_revision,
        .display = .{ .cached_projection = .{
            .status_snapshot_revision = 9,
            .cached = Fingerprint.init("cached"),
        } },
    };
    changed = cached;
    changed.display.cached_projection.status_snapshot_revision += 1;
    try std.testing.expect(!cached.eql(changed));
    changed = cached;
    changed.display.cached_projection.cached = Fingerprint.init("changed cached");
    try std.testing.expect(!cached.eql(changed));

    const combined = ContentToken{
        .repo_epoch = base.repo_epoch,
        .root_identity = base.root_identity,
        .source = base.source,
        .source_session_revision = base.source_session_revision,
        .display = .{ .combined_projection = .init(9) },
    };
    changed = combined;
    changed.display.combined_projection = .init(10);
    try std.testing.expect(!combined.eql(changed));

    const generated = ContentToken{
        .repo_epoch = base.repo_epoch,
        .root_identity = base.root_identity,
        .source = base.source,
        .source_session_revision = base.source_session_revision,
        .display = .{ .generated_untracked = .{
            .status_snapshot_revision = 9,
            .source = Fingerprint.init("generated"),
        } },
    };
    changed = generated;
    changed.display.generated_untracked.source = Fingerprint.init("changed generated");
    try std.testing.expect(!generated.eql(changed));
}

test "generated candidate is not represented as a parser hunk" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "ABCDEFG\nHIJKLMN\n");
    var document = try repository_source.Document.initOwned(allocator, bytes, Fingerprint.init(bytes));
    defer document.deinit(allocator);
    var completed = try buildGenerated(allocator, .{
        .repo_epoch = 1,
        .root_identity = null,
        .source = SourceBasis.init(.unstaged),
        .source_session_revision = 1,
        .display = .{ .generated_untracked = .{ .status_snapshot_revision = 1, .source = document.fingerprint } },
    }, "new.zig", &document, .{
        .identity = .{ .generated_file = .{ .path_key = "new.zig" } },
        .content = .{ .source_side = .{ .side = .new, .mode = .character } },
        .anchor = .{ .hunk_index = 0, .line_index = 0, .leading = 3, .trailing = 4 },
        .focus = .{ .hunk_index = 0, .line_index = 1, .leading = 4, .trailing = 5 },
        .moved = true,
    });
    defer completed.deinit(allocator);
    const clipboard = try completed.clipboardText(allocator);
    defer allocator.free(clipboard);
    try std.testing.expectEqualStrings("DEFG\nHIJKL", clipboard);
    try std.testing.expect(completed.value == .generated_untracked);
    const generated = completed.value.generated_untracked;
    const source = generated.content.source_side;
    try std.testing.expectEqual(diff_selection.Mode.character, source.mode);
    try std.testing.expectEqual(@as(usize, 2), source.fragment.line_count);
    try std.testing.expectEqualDeep(diff_selection.Range{
        .start = .{ .hunk_index = 0, .line_index = 0, .leading = 3, .trailing = 4 },
        .end = .{ .hunk_index = 0, .line_index = 1, .leading = 4, .trailing = 5 },
    }, generated.range);
}

test "parsed candidate retains exact cross-hunk range and character bytes" {
    const allocator = std.testing.allocator;
    const file: diff_parser.FileDiff = .{
        .header = "diff --git a/a b/a",
        .old_path = "a/a",
        .new_path = "b/a",
        .metadata = &.{},
        .hunks = &.{
            .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .section = "", .lines = &.{.{ .kind = .context, .text = "abc", .old_line = 1, .new_line = 1 }} },
            .{ .old_start = 20, .old_count = 1, .new_start = 20, .new_count = 1, .section = "", .lines = &.{.{ .kind = .context, .text = "xyz", .old_line = 20, .new_line = 20 }} },
        },
    };
    const drag: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .{ .source_side = .{ .side = .new, .mode = .character } },
        .anchor = .{ .hunk_index = 0, .line_index = 0, .leading = 1, .trailing = 2 },
        .focus = .{ .hunk_index = 1, .line_index = 0, .leading = 1, .trailing = 2 },
        .moved = true,
    };
    var completed = try buildParsed(allocator, .{
        .repo_epoch = 1,
        .root_identity = null,
        .source = SourceBasis.init(.unstaged),
        .source_session_revision = 1,
        .display = .{ .loaded = Fingerprint.init("multi-hunk") },
    }, file, drag);
    defer completed.deinit(allocator);
    const clipboard = try completed.clipboardText(allocator);
    defer allocator.free(clipboard);
    try std.testing.expectEqualStrings("bc\nxy", clipboard);
    try std.testing.expectEqualDeep(drag.range(), completed.value.parsed_diff.range);
    try std.testing.expectEqual(@as(usize, 2), completed.value.parsed_diff.content.source_side.fragments.line_count);
}

test "parsed candidate owns byte-exact rename paths for the selected side" {
    const allocator = std.testing.allocator;
    const lines = [_]diff_parser.DiffLine{.{
        .kind = .context,
        .text = "valid text",
        .old_line = 1,
        .new_line = 1,
    }};
    const file: diff_parser.FileDiff = .{
        .header = "rename with raw path bytes",
        .old_path = "a/old-\xff.zig",
        .new_path = "b/new-\xfe.zig",
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
    var completed = try buildParsed(allocator, .{
        .repo_epoch = 1,
        .root_identity = null,
        .source = SourceBasis.init(.unstaged),
        .source_session_revision = 1,
        .display = .{ .loaded = Fingerprint.init("rename diff") },
    }, file, .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "new-\xfe.zig" } },
        .content = .{ .source_side = .{ .side = .old, .mode = .character } },
        .anchor = .{ .hunk_index = 0, .line_index = 0, .leading = 0, .trailing = 1 },
        .focus = .{ .hunk_index = 0, .line_index = 0, .leading = 4, .trailing = 5 },
        .moved = true,
    });
    defer completed.deinit(allocator);

    try std.testing.expect(completed.value == .parsed_diff);
    const parsed = completed.value.parsed_diff;
    try std.testing.expectEqualStrings("new-\xfe.zig", parsed.canonical_path);
    try std.testing.expectEqualStrings("old-\xff.zig", parsed.old_path.?);
    try std.testing.expectEqualStrings("new-\xfe.zig", parsed.new_path.?);
    try std.testing.expectEqualStrings("old-\xff.zig", parsed.content.source_side.selected_path);
    try std.testing.expectEqual(diff_selection.Side.old, parsed.content.source_side.side);
}
