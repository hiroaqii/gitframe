//! Page-independent contract for resolving the body currently displayed by a
//! diff surface.
//!
//! Rich Changes and Review page bundles stay behind the vtable. Values may be
//! retained, allocator-owned hunk stages belong to the caller, and borrowed
//! parsed/generated/header data remains valid only until the next surface
//! mutation.

const std = @import("std");
const chasen = @import("chasen");
const theme = @import("theme");
const diff_parser = @import("../../diff/parser.zig");
const diff_render = @import("../../diff/render.zig");
const diff_selection = @import("../../diff/selection.zig");
const diff_view_model = @import("../../diff/view_model.zig");
const repository_source = @import("../../repository/source.zig");
const selection = @import("selection.zig");

pub const ContentToken = selection.ContentToken;

pub const ReducedBodyKind = enum {
    none,
    primary,
    inert,
    projected,
};

pub const SearchUnavailableReason = enum {
    invalid_utf8,
    mixed_stage_view,
    generated_preview,
    staged_new_preview,

    pub fn message(self: SearchUnavailableReason) []const u8 {
        return switch (self) {
            .invalid_utf8 => "search is unavailable because diff content is not valid UTF-8",
            .mixed_stage_view => "search is unavailable for mixed staged/unstaged view",
            .generated_preview => "search is unavailable for generated file preview",
            .staged_new_preview => "search is unavailable for staged new file preview",
        };
    }
};

pub const SearchUnfoldPolicy = enum {
    unfold_displayed,
    unfold_underlying,
    suppressed,
};

pub const FoldedHunksSource = enum {
    empty,
    underlying_load,
};

pub const HunkInteractionAvailability = enum {
    available,
    unavailable,
    inert_invalid_utf8,
};

/// Value-only policy summary. It may outlive a resolver call.
pub const ResolvedTarget = struct {
    kind: ReducedBodyKind,
    line_count: usize,
    hunk_interaction: HunkInteractionAvailability,
    status_rows: usize,
    search_unavailable: ?SearchUnavailableReason,
    search_unfold_policy: SearchUnfoldPolicy,
    folded_hunks_source: FoldedHunksSource,
};

pub const ParsedSelectionTarget = struct {
    file: diff_parser.FileDiff,
    line_index: diff_view_model.RenderedLineIndex,
    folded_hunks: []const bool,
    identity: diff_selection.Identity,
};

pub const SearchTarget = struct {
    file: diff_parser.FileDiff,
    line_index: diff_view_model.RenderedLineIndex,
    folded_hunks: []const bool,
};

pub const GeneratedBody = struct {
    path: []const u8,
    source: *const repository_source.Document,
};

pub const DiffHeaderTarget = struct {
    identity: diff_selection.HeaderIdentity,
    display_path: []const u8,
};

/// Page-independent render inputs. The resolver chooses the rich projected,
/// generated, status, pending, or inert body and propagates renderer errors.
pub const RenderProjectedBodyArgs = struct {
    surface: *chasen.Surface,
    requested_mode: diff_render.DisplayMode,
    display_mode_toggle_key: ?[]const u8 = null,
    scroll: usize,
    horizontal_scroll: usize,
    pane_active: bool,
    line_numbers: bool,
    highlighted_hunk: ?usize,
    cursor_offset: ?usize,
    palette: theme.Palette,
    selection: ?diff_selection.View,
    header_selection: bool,
};

pub const BodyResolver = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// The seven conceptual entries are represented by eleven function
    /// pointers because component 5 is the five-function parsed-body accessor
    /// group fixed by issue #34's approved plan.
    pub const VTable = struct {
        resolvedTarget: *const fn (ctx: *anyopaque) ResolvedTarget,
        hunkStagePresentation: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, file_index: usize) anyerror!diff_render.HunkStagePresentation,
        contentToken: *const fn (ctx: *anyopaque) ?ContentToken,
        renderProjectedBody: *const fn (ctx: *anyopaque, args: RenderProjectedBodyArgs) anyerror!void,
        parsedSelectionTarget: *const fn (ctx: *anyopaque, expected: ?diff_selection.Identity) ?ParsedSelectionTarget,
        displayedDiffFile: *const fn (ctx: *anyopaque) ?diff_parser.FileDiff,
        displayedSearchTarget: *const fn (ctx: *anyopaque, mode: diff_render.DisplayMode) ?SearchTarget,
        displayedDiffLineIndex: *const fn (ctx: *anyopaque, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex,
        displayedDiffLineCount: *const fn (ctx: *anyopaque) usize,
        generatedBody: *const fn (ctx: *anyopaque) ?GeneratedBody,
        displayedDiffHeaderTarget: *const fn (ctx: *anyopaque, expected: ?diff_selection.HeaderIdentity) ?DiffHeaderTarget,
    };

    pub fn resolvedTarget(self: BodyResolver) ResolvedTarget {
        return self.vtable.resolvedTarget(self.ctx);
    }

    /// A returned `.per_hunk` slice is owned by `allocator` and must be freed
    /// by the caller. Uniform tags allocate nothing.
    pub fn hunkStagePresentation(self: BodyResolver, allocator: std.mem.Allocator, file_index: usize) !diff_render.HunkStagePresentation {
        return self.vtable.hunkStagePresentation(self.ctx, allocator, file_index);
    }

    pub fn contentToken(self: BodyResolver) ?ContentToken {
        return self.vtable.contentToken(self.ctx);
    }

    pub fn renderProjectedBody(self: BodyResolver, args: RenderProjectedBodyArgs) !void {
        return self.vtable.renderProjectedBody(self.ctx, args);
    }

    pub fn parsedSelectionTarget(self: BodyResolver, expected: ?diff_selection.Identity) ?ParsedSelectionTarget {
        return self.vtable.parsedSelectionTarget(self.ctx, expected);
    }

    pub fn displayedDiffFile(self: BodyResolver) ?diff_parser.FileDiff {
        return self.vtable.displayedDiffFile(self.ctx);
    }

    pub fn displayedSearchTarget(self: BodyResolver, mode: diff_render.DisplayMode) ?SearchTarget {
        return self.vtable.displayedSearchTarget(self.ctx, mode);
    }

    pub fn displayedDiffLineIndex(self: BodyResolver, mode: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
        return self.vtable.displayedDiffLineIndex(self.ctx, mode);
    }

    pub fn displayedDiffLineCount(self: BodyResolver) usize {
        return self.vtable.displayedDiffLineCount(self.ctx);
    }

    pub fn generatedBody(self: BodyResolver) ?GeneratedBody {
        return self.vtable.generatedBody(self.ctx);
    }

    pub fn displayedDiffHeaderTarget(self: BodyResolver, expected: ?diff_selection.HeaderIdentity) ?DiffHeaderTarget {
        return self.vtable.displayedDiffHeaderTarget(self.ctx, expected);
    }
};

test "body resolver contract fixes policy and vtable vocabulary" {
    const resolved_fields = std.meta.fields(ResolvedTarget);
    const expected_resolved = [_][]const u8{
        "kind",
        "line_count",
        "hunk_interaction",
        "status_rows",
        "search_unavailable",
        "search_unfold_policy",
        "folded_hunks_source",
    };
    try std.testing.expectEqual(expected_resolved.len, resolved_fields.len);
    inline for (resolved_fields, expected_resolved) |field, expected| {
        try std.testing.expectEqualStrings(expected, field.name);
    }

    const vtable_fields = std.meta.fields(BodyResolver.VTable);
    const expected_vtable = [_][]const u8{
        "resolvedTarget",
        "hunkStagePresentation",
        "contentToken",
        "renderProjectedBody",
        "parsedSelectionTarget",
        "displayedDiffFile",
        "displayedSearchTarget",
        "displayedDiffLineIndex",
        "displayedDiffLineCount",
        "generatedBody",
        "displayedDiffHeaderTarget",
    };
    try std.testing.expectEqual(expected_vtable.len, vtable_fields.len);
    inline for (vtable_fields, expected_vtable) |field, expected| {
        try std.testing.expectEqualStrings(expected, field.name);
    }

    try std.testing.expectEqualStrings(
        "search is unavailable because diff content is not valid UTF-8",
        SearchUnavailableReason.invalid_utf8.message(),
    );
    try std.testing.expectEqualStrings(
        "search is unavailable for mixed staged/unstaged view",
        SearchUnavailableReason.mixed_stage_view.message(),
    );
    try std.testing.expectEqualStrings(
        "search is unavailable for generated file preview",
        SearchUnavailableReason.generated_preview.message(),
    );
    try std.testing.expectEqualStrings(
        "search is unavailable for staged new file preview",
        SearchUnavailableReason.staged_new_preview.message(),
    );
}

test "body resolver forwards value allocation and borrow entries through vtable" {
    const Fake = struct {
        resolved: ResolvedTarget,

        fn from(ctx: *anyopaque) *@This() {
            return @ptrCast(@alignCast(ctx));
        }

        fn resolvedTarget(ctx: *anyopaque) ResolvedTarget {
            return from(ctx).resolved;
        }

        fn hunkStagePresentation(_: *anyopaque, _: std.mem.Allocator, _: usize) anyerror!diff_render.HunkStagePresentation {
            return .all_staged;
        }

        fn contentToken(_: *anyopaque) ?ContentToken {
            return null;
        }

        fn renderProjectedBody(_: *anyopaque, _: RenderProjectedBodyArgs) anyerror!void {}

        fn parsedSelectionTarget(_: *anyopaque, _: ?diff_selection.Identity) ?ParsedSelectionTarget {
            return null;
        }

        fn displayedDiffFile(_: *anyopaque) ?diff_parser.FileDiff {
            return null;
        }

        fn displayedSearchTarget(_: *anyopaque, _: diff_render.DisplayMode) ?SearchTarget {
            return null;
        }

        fn displayedDiffLineIndex(_: *anyopaque, _: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
            return null;
        }

        fn displayedDiffLineCount(_: *anyopaque) usize {
            return 17;
        }

        fn generatedBody(_: *anyopaque) ?GeneratedBody {
            return null;
        }

        fn displayedDiffHeaderTarget(_: *anyopaque, _: ?diff_selection.HeaderIdentity) ?DiffHeaderTarget {
            return null;
        }

        const vtable: BodyResolver.VTable = .{
            .resolvedTarget = resolvedTarget,
            .hunkStagePresentation = hunkStagePresentation,
            .contentToken = contentToken,
            .renderProjectedBody = renderProjectedBody,
            .parsedSelectionTarget = parsedSelectionTarget,
            .displayedDiffFile = displayedDiffFile,
            .displayedSearchTarget = displayedSearchTarget,
            .displayedDiffLineIndex = displayedDiffLineIndex,
            .displayedDiffLineCount = displayedDiffLineCount,
            .generatedBody = generatedBody,
            .displayedDiffHeaderTarget = displayedDiffHeaderTarget,
        };
    };

    var fake: Fake = .{ .resolved = .{
        .kind = .projected,
        .line_count = 11,
        .hunk_interaction = .available,
        .status_rows = 3,
        .search_unavailable = .mixed_stage_view,
        .search_unfold_policy = .suppressed,
        .folded_hunks_source = .empty,
    } };
    const resolver: BodyResolver = .{ .ctx = &fake, .vtable = &Fake.vtable };

    try std.testing.expectEqualDeep(fake.resolved, resolver.resolvedTarget());
    try std.testing.expect((try resolver.hunkStagePresentation(std.testing.allocator, 9)) == .all_staged);
    try std.testing.expect(resolver.contentToken() == null);
    try std.testing.expect(resolver.parsedSelectionTarget(null) == null);
    try std.testing.expect(resolver.displayedDiffFile() == null);
    try std.testing.expect(resolver.displayedSearchTarget(.unified) == null);
    try std.testing.expect(resolver.displayedDiffLineIndex(.side_by_side) == null);
    try std.testing.expectEqual(@as(usize, 17), resolver.displayedDiffLineCount());
    try std.testing.expect(resolver.generatedBody() == null);
    try std.testing.expect(resolver.displayedDiffHeaderTarget(null) == null);
}

test "body resolver forwards render arguments and propagates renderer errors" {
    const Fake = struct {
        expected_surface: *chasen.Surface,
        called: bool = false,

        fn from(ctx: *anyopaque) *@This() {
            return @ptrCast(@alignCast(ctx));
        }

        fn renderProjectedBody(ctx: *anyopaque, args: RenderProjectedBodyArgs) anyerror!void {
            const self = from(ctx);
            self.called = true;
            if (args.surface != self.expected_surface) return error.SurfaceNotForwarded;
            if (args.requested_mode != .side_by_side) return error.ModeNotForwarded;
            if (args.scroll != 7 or args.horizontal_scroll != 11) return error.ScrollNotForwarded;
            if (args.pane_active or args.line_numbers) return error.FlagsNotForwarded;
            if (args.highlighted_hunk != 13 or args.cursor_offset != 17) return error.CursorNotForwarded;
            if (!args.header_selection) return error.HeaderSelectionNotForwarded;
            return error.InjectedRendererFailure;
        }
    };

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(20, 4);
    defer ts.deinit();
    var fake: Fake = .{ .expected_surface = &ts.surface };
    const vtable = BodyResolver.VTable{
        .resolvedTarget = struct {
            fn callback(_: *anyopaque) ResolvedTarget {
                return .{
                    .kind = .none,
                    .line_count = 0,
                    .hunk_interaction = .unavailable,
                    .status_rows = 0,
                    .search_unavailable = null,
                    .search_unfold_policy = .suppressed,
                    .folded_hunks_source = .underlying_load,
                };
            }
        }.callback,
        .hunkStagePresentation = struct {
            fn callback(_: *anyopaque, _: std.mem.Allocator, _: usize) anyerror!diff_render.HunkStagePresentation {
                return .all_unstaged;
            }
        }.callback,
        .contentToken = struct {
            fn callback(_: *anyopaque) ?ContentToken {
                return null;
            }
        }.callback,
        .renderProjectedBody = Fake.renderProjectedBody,
        .parsedSelectionTarget = struct {
            fn callback(_: *anyopaque, _: ?diff_selection.Identity) ?ParsedSelectionTarget {
                return null;
            }
        }.callback,
        .displayedDiffFile = struct {
            fn callback(_: *anyopaque) ?diff_parser.FileDiff {
                return null;
            }
        }.callback,
        .displayedSearchTarget = struct {
            fn callback(_: *anyopaque, _: diff_render.DisplayMode) ?SearchTarget {
                return null;
            }
        }.callback,
        .displayedDiffLineIndex = struct {
            fn callback(_: *anyopaque, _: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
                return null;
            }
        }.callback,
        .displayedDiffLineCount = struct {
            fn callback(_: *anyopaque) usize {
                return 0;
            }
        }.callback,
        .generatedBody = struct {
            fn callback(_: *anyopaque) ?GeneratedBody {
                return null;
            }
        }.callback,
        .displayedDiffHeaderTarget = struct {
            fn callback(_: *anyopaque, _: ?diff_selection.HeaderIdentity) ?DiffHeaderTarget {
                return null;
            }
        }.callback,
    };
    const resolver: BodyResolver = .{ .ctx = &fake, .vtable = &vtable };

    try std.testing.expectError(error.InjectedRendererFailure, resolver.renderProjectedBody(.{
        .surface = &ts.surface,
        .requested_mode = .side_by_side,
        .scroll = 7,
        .horizontal_scroll = 11,
        .pane_active = false,
        .line_numbers = false,
        .highlighted_hunk = 13,
        .cursor_offset = 17,
        .palette = .default(),
        .selection = null,
        .header_selection = true,
    }));
    try std.testing.expect(fake.called);
}
