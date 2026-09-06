const std = @import("std");
const diff_search = @import("diff/search.zig");

comptime {
    std.testing.refAllDecls(diff_search);
}
