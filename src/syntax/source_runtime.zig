const std = @import("std");
const build_options = @import("build_options");
const source_document = @import("../repository/source.zig");
const source_spans = @import("source.zig");

/// Page code checks this before creating intent, not merely inside the adapter.
/// A provider-none build should not pay for a second root-safe read and source
/// model only to receive an empty decoration result.
pub const enabled = build_options.syntax_provider_flow_syntax;

pub fn buildSourceSpans(
    allocator: std.mem.Allocator,
    io: std.Io,
    document: *const source_document.Document,
    path: []const u8,
) !source_spans.SourceSpans {
    if (enabled) {
        return @import("source_flow_syntax.zig").buildSourceSpans(allocator, io, document, path);
    }
    return @import("source_none.zig").buildSourceSpans(allocator, io, document, path);
}
