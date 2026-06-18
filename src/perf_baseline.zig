const std = @import("std");
const perf_baseline = @import("tools/perf_baseline.zig");

pub fn main(init: std.process.Init) !void {
    return perf_baseline.main(init);
}
