const std = @import("std");

const diff_file = @import("../diff/file.zig");
const diff_parser = @import("../diff/parser.zig");
const diff_search = @import("../diff/search.zig");
const diff_view_model = @import("../diff/view_model.zig");
const file_tree = @import("../file_tree.zig");
const sidebar_view_model = @import("../sidebar/view_model.zig");

// Keep this stricter than a plain import root. Zig analyzes function bodies
// lazily, so the exported function below exercises the shared core path that
// should stay independent from terminal-only renderer/runtime code.
comptime {
    refAllDecls(diff_file);
    refAllDecls(diff_parser);
    refAllDecls(diff_search);
    refAllDecls(diff_view_model);
    refAllDecls(file_tree);
    refAllDecls(sidebar_view_model);
}

fn refAllDecls(comptime namespace: type) void {
    // Keep this shallow on purpose: recursive decl walking expands through
    // mutually-referential core types and hits comptime branch limits. The
    // exported check function below covers the important runtime paths.
    for (@typeInfo(namespace).@"struct".decls) |decl| {
        _ = @field(namespace, decl.name);
    }
}

// This is not a browser runtime entry point. It only proves that GitFrame's
// parser/tree/view-model core can compile and run as wasm32-freestanding code.
pub fn gitframeCoreWasmCompileCheck() usize {
    var buffer: [128 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const document = diff_parser.parse(allocator, sample_diff) catch unreachable;
    const tree = file_tree.build(allocator, document) catch unreachable;
    const cache = diff_view_model.RenderedLineCache.build(allocator, document) catch unreachable;

    const file = document.files[0];
    const index = cache.indexFor(0, .side_by_side) orelse unreachable;
    const match = diff_search.findMatch(file, .side_by_side, "new", null, .forward) orelse unreachable;

    var collapsed: file_tree.CollapsedSet = .empty;
    const visible_nodes = [_]usize{0};
    const reviewed_files = [_]bool{false};
    const row = sidebar_view_model.visibleRowAt(tree, &collapsed, &reviewed_files, &visible_nodes, 0, 0) orelse unreachable;

    return document.files.len +
        tree.nodes.len +
        index.lineCount() +
        @intFromBool(std.meta.eql(match.coordinate, diff_view_model.BodyCoordinate{ .hunk_line = .{ .hunk_index = 0, .line_index = 1 } })) +
        row.stats.added;
}

const sample_diff =
    \\diff --git a/a b/a
    \\index 1..2 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -1,2 +1,2 @@
    \\-old
    \\+new
    \\
;
