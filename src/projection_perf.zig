const projection_perf = @import("tools/projection_perf.zig");

pub fn main(init: std.process.Init) !void {
    return projection_perf.main(init);
}

const std = @import("std");
