const std = @import("std");
const diff_parser = @import("../diff/parser.zig");
const provider = @import("provider.zig");

pub fn buildDocumentSpans(_: std.mem.Allocator, _: std.Io, _: diff_parser.DiffDocument) !provider.DocumentSpans {
    return .empty();
}
