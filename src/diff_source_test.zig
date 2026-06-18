const std = @import("std");
const diff_source = @import("diff/source.zig");

comptime {
    std.testing.refAllDecls(diff_source);
}
