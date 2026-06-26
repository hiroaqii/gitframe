const std = @import("std");
const context = @import("../context.zig");
const context_export = @import("../context_export.zig");

pub const Decision = enum {
    approved,
    needs_changes,
    canceled,

    pub fn exitCode(self: Decision) u8 {
        return switch (self) {
            .approved => 0,
            .needs_changes => 2,
            .canceled => 130,
        };
    }

    fn jsonName(self: Decision) []const u8 {
        return switch (self) {
            .approved => "approved",
            .needs_changes => "needs_changes",
            .canceled => "canceled",
        };
    }
};

/// Caller-owned review result buffer.
///
/// GitFrame serializes this before asking Chasen to quit. `main.zig` prints the
/// completed buffer after terminal teardown, so stdout stays clean for tools
/// that consume the review decision.
pub const Output = struct {
    json: std.ArrayList(u8) = .empty,
    exit_code: u8 = 0,
    ready: bool = false,

    pub fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        self.json.deinit(allocator);
        self.* = .{};
    }

    pub fn set(
        self: *Output,
        allocator: std.mem.Allocator,
        decision: Decision,
        selection: context.SelectionContext,
        reviewed_paths: []const []const u8,
    ) !void {
        var allocating: std.Io.Writer.Allocating = .init(allocator);
        errdefer allocating.deinit();

        try writeJson(&allocating.writer, decision, selection, reviewed_paths);

        const next_json = allocating.toArrayList();
        self.json.deinit(allocator);
        self.json = next_json;
        self.exit_code = decision.exitCode();
        self.ready = true;
    }
};

fn writeJson(
    writer: *std.Io.Writer,
    decision: Decision,
    selection: context.SelectionContext,
    reviewed_paths: []const []const u8,
) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"schema_version\":1");
    try writer.writeAll(",\"decision\":");
    try context_export.writeStringValue(writer, decision.jsonName());
    try writer.print(",\"exit_code\":{d}", .{decision.exitCode()});
    try writer.writeAll(",\"repo_root\":");
    try context_export.writeOptionalStringValue(writer, selection.repo_root);
    try writer.writeAll(",\"source_kind\":");
    try context_export.writeStringValue(writer, context_export.sourceKindName(selection.source.kind));
    try writer.writeAll(",\"source_label\":");
    try context_export.writeStringValue(writer, selection.source.label);
    try writer.writeAll(",\"selection\":");
    try context_export.writeSelectionValue(writer, selection.selected);
    try writer.writeAll(",\"reviewed_files\":[");
    for (reviewed_paths, 0..) |path, index| {
        if (index != 0) try writer.writeAll(",");
        try context_export.writeStringValue(writer, path);
    }
    try writer.writeAll("],\"message\":null}\n");
}

test "Output serializes approved review result" {
    const allocator = std.testing.allocator;
    var output: Output = .{};
    defer output.deinit(allocator);

    const reviewed_paths = [_][]const u8{ "src/app.zig", "src/main.zig" };
    try output.set(allocator, .approved, .{
        .repo_root = "/repo",
        .source = .{ .kind = .unstaged, .label = "unstaged changes" },
        .selected = .{ .diff_file = .{
            .file_index = 0,
            .display_path = "src/app.zig",
            .path_key = "src/app.zig",
            .hunk_index = 1,
        } },
    }, reviewed_paths[0..]);

    try std.testing.expect(output.ready);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"decision\":\"approved\",\"exit_code\":0,\"repo_root\":\"/repo\",\"source_kind\":\"unstaged\",\"source_label\":\"unstaged changes\",\"selection\":{\"kind\":\"diff_file\",\"file_index\":0,\"display_path\":\"src/app.zig\",\"path_key\":\"src/app.zig\",\"hunk_index\":1},\"reviewed_files\":[\"src/app.zig\",\"src/main.zig\"],\"message\":null}\n",
        output.json.items,
    );
}

test "Output serializes needs-changes exit code" {
    const allocator = std.testing.allocator;
    var output: Output = .{};
    defer output.deinit(allocator);

    try output.set(allocator, .needs_changes, .{
        .repo_root = null,
        .source = .{ .kind = .stdin, .label = "stdin diff" },
        .selected = null,
    }, &.{});

    try std.testing.expect(output.ready);
    try std.testing.expectEqual(@as(u8, 2), output.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.json.items, "\"decision\":\"needs_changes\"") != null);
}

test "Output leaves previous result untouched on serialization failure" {
    const allocator = std.testing.allocator;
    var output: Output = .{};
    defer output.deinit(allocator);

    try output.set(allocator, .canceled, .{
        .repo_root = null,
        .source = .{ .kind = .stdin, .label = "stdin diff" },
        .selected = null,
    }, &.{});

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.WriteFailed, output.set(failing_allocator.allocator(), .approved, .{
        .repo_root = "/repo",
        .source = .{ .kind = .unstaged, .label = "unstaged changes" },
        .selected = null,
    }, &.{}));

    try std.testing.expect(output.ready);
    try std.testing.expectEqual(@as(u8, 130), output.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.json.items, "\"decision\":\"canceled\"") != null);
}
