const std = @import("std");
const source_document = @import("../repository/source.zig");
const source_spans = @import("source.zig");

pub fn buildSourceSpans(
    _: std.mem.Allocator,
    _: std.Io,
    _: *const source_document.Document,
    _: []const u8,
) !source_spans.SourceSpans {
    return .empty();
}
