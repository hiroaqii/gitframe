const std = @import("std");
const diff_view_model = @import("diff/view_model.zig");

comptime {
    std.testing.refAllDecls(diff_view_model);
}
