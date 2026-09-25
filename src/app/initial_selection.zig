//! Construct neutral selection context from the current source and model selection.

const context = @import("../context.zig");
const diff_source = @import("../diff/source.zig");

pub fn contextForSelection(
    source: diff_source.SourceMode,
    repo_root: ?[]const u8,
    selected: ?context.Selection,
) context.SelectionContext {
    return .{
        .repo_root = repo_root,
        .source = switch (source) {
            .unstaged => .{ .kind = .unstaged, .label = "working tree changes" },
            .patch_file => |path| .{ .kind = .patch_file, .label = "patch file", .detail = path },
            .range => |range| .{ .kind = .range, .label = "range", .detail = range },
        },
        .selected = selected,
    };
}
