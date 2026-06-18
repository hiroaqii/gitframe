const std = @import("std");
const sidebar_view_model = @import("sidebar/view_model.zig");

comptime {
    std.testing.refAllDecls(sidebar_view_model);
}
