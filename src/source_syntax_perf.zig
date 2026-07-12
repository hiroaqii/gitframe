const source_syntax_perf = @import("tools/source_syntax_perf.zig");

pub fn main(init: std.process.Init) !void {
    return source_syntax_perf.main(init);
}

const std = @import("std");
