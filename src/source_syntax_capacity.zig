const source_syntax_capacity = @import("tools/source_syntax_capacity.zig");

pub fn main(init: std.process.Init) !void {
    return source_syntax_capacity.main(init);
}

const std = @import("std");
