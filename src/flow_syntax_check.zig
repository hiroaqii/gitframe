const std = @import("std");
const flow_syntax = @import("flow_syntax");

test "flow-syntax exposes the API needed by GitFrame provider adapter" {
    try std.testing.expect(flow_syntax.FileType.guess_static("src/main.zig", "const x = 1;") != null);
    try std.testing.expect(@hasDecl(flow_syntax, "QueryCache"));
    try std.testing.expect(@hasDecl(flow_syntax, "create_guess_file_type_static"));
    try std.testing.expect(@hasDecl(flow_syntax, "Range"));
    try std.testing.expect(@hasDecl(flow_syntax, "Point"));
}
