const std = @import("std");
const build_options = @import("build_options");
const diff_parser = @import("../diff/parser.zig");
const provider = @import("provider.zig");
const provider_none = @import("provider_none.zig");
const text_eligibility = @import("../diff/text_eligibility.zig");

pub fn buildDocumentSpans(allocator: std.mem.Allocator, io: std.Io, document: diff_parser.DiffDocument, eligibility: []const text_eligibility.FileTextEligibility) !provider.DocumentSpans {
    if (build_options.syntax_provider_flow_syntax) {
        return @import("provider_flow_syntax.zig").buildDocumentSpans(allocator, io, document, eligibility);
    }
    return provider_none.buildDocumentSpans(allocator, io, document, eligibility);
}
