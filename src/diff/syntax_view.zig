//! Borrowed syntax lookup for direct and origin-projected diff documents.
//!
//! A combined diff reorders complete hunks from two independently highlighted
//! component documents. This view preserves that component identity without
//! synthesizing or owning a second `DocumentSpans`: every lookup resolves the
//! projected hunk through its explicit origin, then borrows the exact original
//! hunk/line/side spans. It performs no allocation and has no `deinit`.

const std = @import("std");
const syntax_provider = @import("../syntax/provider.zig");
const syntax_style = @import("../syntax/style.zig");
const syntax_token = @import("../syntax/token.zig");
const hunk_projection = @import("hunk_projection.zig");

pub const LineLookup = struct {
    hunk_index: usize,
    line_index: usize,
    side: syntax_provider.Side,
};

pub const View = union(enum) {
    direct: Direct,
    combined: Combined,

    pub const Direct = struct {
        document: *const syntax_provider.DocumentSpans,
        file_index: usize,
    };

    pub const Combined = struct {
        origins: []const hunk_projection.PresentationSyntaxOrigin,
        cached: *const syntax_provider.DocumentSpans,
        unstaged: *const syntax_provider.DocumentSpans,
    };

    pub fn initDirect(document: *const syntax_provider.DocumentSpans, file_index: usize) View {
        return .{ .direct = .{
            .document = document,
            .file_index = file_index,
        } };
    }

    pub fn initCombined(
        origins: []const hunk_projection.PresentationSyntaxOrigin,
        cached: *const syntax_provider.DocumentSpans,
        unstaged: *const syntax_provider.DocumentSpans,
    ) View {
        return .{ .combined = .{
            .origins = origins,
            .cached = cached,
            .unstaged = unstaged,
        } };
    }

    pub fn lineSpans(self: View, lookup: LineLookup) syntax_token.LineSpans {
        const hunk = self.resolveHunk(lookup.hunk_index) orelse return .empty();
        return hunk.document.lineSpans(.{
            .file_index = hunk.file_index,
            .hunk_index = hunk.hunk_index,
            .line_index = lookup.line_index,
            .side = lookup.side,
        });
    }

    /// Reports whether the same resolved hunk-side used by `lineSpans` has at
    /// least one token which changes the foreground. The renderer uses this
    /// signal to decide whether a plain diff prefix remains necessary.
    pub fn hunkSideHasVisibleSyntax(self: View, hunk_index: usize, side: syntax_provider.Side) bool {
        const resolved = self.resolveHunk(hunk_index) orelse return false;
        const hunk = resolved.document.files[resolved.file_index].hunks[resolved.hunk_index];
        for (hunk.lines) |line| {
            for (line.forSide(side).spans) |span| {
                if (syntax_style.changesForeground(span.role)) return true;
            }
        }
        return false;
    }

    const ResolvedHunk = struct {
        document: *const syntax_provider.DocumentSpans,
        file_index: usize,
        hunk_index: usize,
    };

    fn resolveHunk(self: View, projected_hunk_index: usize) ?ResolvedHunk {
        return switch (self) {
            .direct => |direct| resolveDocumentHunk(direct.document, direct.file_index, projected_hunk_index),
            .combined => |combined| if (projected_hunk_index >= combined.origins.len)
                null
            else switch (combined.origins[projected_hunk_index]) {
                .cached => |original_hunk_index| resolveDocumentHunk(combined.cached, 0, original_hunk_index),
                .unstaged => |original_hunk_index| resolveDocumentHunk(combined.unstaged, 0, original_hunk_index),
            },
        };
    }
};

fn resolveDocumentHunk(document: *const syntax_provider.DocumentSpans, file_index: usize, hunk_index: usize) ?View.ResolvedHunk {
    if (file_index >= document.files.len) return null;
    if (hunk_index >= document.files[file_index].hunks.len) return null;
    return .{
        .document = document,
        .file_index = file_index,
        .hunk_index = hunk_index,
    };
}

test "combined syntax view resolves reordered hunks by component origin" {
    const cached_hunk_0_old = [_]syntax_token.TokenSpan{.{ .start = 0, .end = 1, .role = .keyword }};
    const cached_hunk_0_new = [_]syntax_token.TokenSpan{.{ .start = 0, .end = 1, .role = .plain }};
    const cached_hunk_1_new = [_]syntax_token.TokenSpan{.{ .start = 0, .end = 1, .role = .number }};
    var cached_hunk_0_lines = [_]syntax_provider.LineEntry{.{
        .old = .{ .spans = &cached_hunk_0_old },
        .new = .{ .spans = &cached_hunk_0_new },
    }};
    var cached_hunk_1_lines = [_]syntax_provider.LineEntry{.{ .new = .{ .spans = &cached_hunk_1_new } }};
    var cached_hunks = [_]syntax_provider.HunkSpans{
        .{ .lines = &cached_hunk_0_lines },
        .{ .lines = &cached_hunk_1_lines },
    };
    var cached_files = [_]syntax_provider.FileSpans{.{ .hunks = &cached_hunks }};
    const cached: syntax_provider.DocumentSpans = .{ .files = &cached_files };

    const unstaged_hunk_0_new = [_]syntax_token.TokenSpan{.{ .start = 0, .end = 1, .role = .variable }};
    const unstaged_hunk_1_old = [_]syntax_token.TokenSpan{.{ .start = 0, .end = 1, .role = .variable }};
    const unstaged_hunk_1_new = [_]syntax_token.TokenSpan{.{ .start = 0, .end = 1, .role = .string }};
    const unstaged_hunk_1_second_new = [_]syntax_token.TokenSpan{.{ .start = 1, .end = 2, .role = .property }};
    var unstaged_hunk_0_lines = [_]syntax_provider.LineEntry{.{ .new = .{ .spans = &unstaged_hunk_0_new } }};
    var unstaged_hunk_1_lines = [_]syntax_provider.LineEntry{
        .{
            .old = .{ .spans = &unstaged_hunk_1_old },
            .new = .{ .spans = &unstaged_hunk_1_new },
        },
        .{ .new = .{ .spans = &unstaged_hunk_1_second_new } },
    };
    var unstaged_hunks = [_]syntax_provider.HunkSpans{
        .{ .lines = &unstaged_hunk_0_lines },
        .{ .lines = &unstaged_hunk_1_lines },
    };
    var unstaged_files = [_]syntax_provider.FileSpans{.{ .hunks = &unstaged_hunks }};
    const unstaged: syntax_provider.DocumentSpans = .{ .files = &unstaged_files };

    const origins = [_]hunk_projection.PresentationSyntaxOrigin{
        .{ .unstaged = 1 },
        .{ .cached = 0 },
    };
    // Fresh action authority is intentionally different. If syntax lookup is
    // ever rewired to that map, the role assertions below resolve the wrong
    // component and ordinal instead of merely producing an equivalent span.
    const action_origins = [_]hunk_projection.HunkActionOrigin{
        .{ .cached = 0 },
        .{ .unstaged = 0 },
    };
    try std.testing.expect(switch (origins[0]) {
        .unstaged => true,
        .cached => false,
    });
    try std.testing.expect(switch (action_origins[0]) {
        .cached => true,
        .unstaged => false,
    });
    const view = View.initCombined(&origins, &cached, &unstaged);

    try expectOnlyRole(.string, view.lineSpans(.{ .hunk_index = 0, .line_index = 0, .side = .new }));
    try expectOnlyRole(.property, view.lineSpans(.{ .hunk_index = 0, .line_index = 1, .side = .new }));
    try expectOnlyRole(.variable, view.lineSpans(.{ .hunk_index = 0, .line_index = 0, .side = .old }));
    try expectOnlyRole(.keyword, view.lineSpans(.{ .hunk_index = 1, .line_index = 0, .side = .old }));
    try expectOnlyRole(.plain, view.lineSpans(.{ .hunk_index = 1, .line_index = 0, .side = .new }));

    try std.testing.expect(view.hunkSideHasVisibleSyntax(0, .new));
    try std.testing.expect(!view.hunkSideHasVisibleSyntax(0, .old));
    try std.testing.expect(view.hunkSideHasVisibleSyntax(1, .old));
    try std.testing.expect(!view.hunkSideHasVisibleSyntax(1, .new));
}

test "combined syntax view fails closed without component or ordinal fallback" {
    const unstaged_tokens = [_]syntax_token.TokenSpan{.{ .start = 0, .end = 1, .role = .keyword }};
    var unstaged_lines = [_]syntax_provider.LineEntry{.{ .new = .{ .spans = &unstaged_tokens } }};
    var unstaged_hunks = [_]syntax_provider.HunkSpans{.{ .lines = &unstaged_lines }};
    var unstaged_files = [_]syntax_provider.FileSpans{.{ .hunks = &unstaged_hunks }};
    const unstaged: syntax_provider.DocumentSpans = .{ .files = &unstaged_files };
    const cached = syntax_provider.DocumentSpans.empty();
    const origins = [_]hunk_projection.PresentationSyntaxOrigin{.{ .cached = 0 }};
    const view = View.initCombined(&origins, &cached, &unstaged);

    try expectEmpty(view.lineSpans(.{ .hunk_index = 0, .line_index = 0, .side = .new }));
    try expectEmpty(view.lineSpans(.{ .hunk_index = 1, .line_index = 0, .side = .new }));
    try std.testing.expect(!view.hunkSideHasVisibleSyntax(0, .new));
}

test "combined syntax view returns empty spans for invalid original line and hunk indexes" {
    const tokens = [_]syntax_token.TokenSpan{.{ .start = 0, .end = 1, .role = .keyword }};
    var lines = [_]syntax_provider.LineEntry{.{ .new = .{ .spans = &tokens } }};
    var hunks = [_]syntax_provider.HunkSpans{.{ .lines = &lines }};
    var files = [_]syntax_provider.FileSpans{.{ .hunks = &hunks }};
    const document: syntax_provider.DocumentSpans = .{ .files = &files };
    const origins = [_]hunk_projection.PresentationSyntaxOrigin{
        .{ .unstaged = 0 },
        .{ .cached = 9 },
    };
    const view = View.initCombined(&origins, &document, &document);

    try expectEmpty(view.lineSpans(.{ .hunk_index = 0, .line_index = 8, .side = .new }));
    try expectEmpty(view.lineSpans(.{ .hunk_index = 1, .line_index = 0, .side = .new }));
    try std.testing.expect(!view.hunkSideHasVisibleSyntax(1, .new));
}

test "direct syntax view keeps exact file hunk line and side identity" {
    const first_tokens = [_]syntax_token.TokenSpan{.{ .start = 0, .end = 1, .role = .variable }};
    const second_old_tokens = [_]syntax_token.TokenSpan{.{ .start = 0, .end = 1, .role = .comment }};
    const second_new_tokens = [_]syntax_token.TokenSpan{.{ .start = 0, .end = 1, .role = .function }};
    var first_lines = [_]syntax_provider.LineEntry{.{ .new = .{ .spans = &first_tokens } }};
    var second_lines = [_]syntax_provider.LineEntry{.{
        .old = .{ .spans = &second_old_tokens },
        .new = .{ .spans = &second_new_tokens },
    }};
    var first_hunks = [_]syntax_provider.HunkSpans{.{ .lines = &first_lines }};
    var second_hunks = [_]syntax_provider.HunkSpans{.{ .lines = &second_lines }};
    var files = [_]syntax_provider.FileSpans{
        .{ .hunks = &first_hunks },
        .{ .hunks = &second_hunks },
    };
    const document: syntax_provider.DocumentSpans = .{ .files = &files };
    const view = View.initDirect(&document, 1);

    try expectOnlyRole(.comment, view.lineSpans(.{ .hunk_index = 0, .line_index = 0, .side = .old }));
    try expectOnlyRole(.function, view.lineSpans(.{ .hunk_index = 0, .line_index = 0, .side = .new }));
    try std.testing.expect(view.hunkSideHasVisibleSyntax(0, .old));
    try std.testing.expect(view.hunkSideHasVisibleSyntax(0, .new));

    const missing_file = View.initDirect(&document, 2);
    try expectEmpty(missing_file.lineSpans(.{ .hunk_index = 0, .line_index = 0, .side = .new }));
    try std.testing.expect(!missing_file.hunkSideHasVisibleSyntax(0, .new));
}

test "direct and combined syntax views keep provider-empty documents plain" {
    const empty = syntax_provider.DocumentSpans.empty();
    const direct = View.initDirect(&empty, 0);
    try expectEmpty(direct.lineSpans(.{ .hunk_index = 0, .line_index = 0, .side = .new }));
    try std.testing.expect(!direct.hunkSideHasVisibleSyntax(0, .new));

    const origins = [_]hunk_projection.PresentationSyntaxOrigin{.{ .unstaged = 0 }};
    const combined = View.initCombined(&origins, &empty, &empty);
    try expectEmpty(combined.lineSpans(.{ .hunk_index = 0, .line_index = 0, .side = .new }));
    try std.testing.expect(!combined.hunkSideHasVisibleSyntax(0, .new));
}

fn expectOnlyRole(expected: syntax_token.TokenRole, spans: syntax_token.LineSpans) !void {
    try std.testing.expectEqual(@as(usize, 1), spans.spans.len);
    try std.testing.expectEqual(expected, spans.spans[0].role);
}

fn expectEmpty(spans: syntax_token.LineSpans) !void {
    try std.testing.expectEqual(@as(usize, 0), spans.spans.len);
}
