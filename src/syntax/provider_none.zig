const std = @import("std");
const diff_parser = @import("../diff/parser.zig");
const provider = @import("provider.zig");
const text_eligibility = @import("../diff/text_eligibility.zig");

pub fn buildDocumentSpans(_: std.mem.Allocator, _: std.Io, document: diff_parser.DiffDocument, eligibility: []const text_eligibility.FileTextEligibility) !provider.DocumentSpans {
    std.debug.assert(eligibility.len == document.files.len);
    return .empty();
}
