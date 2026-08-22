//! Side-effect-free `gitframe review-capabilities` process adapter.

const std = @import("std");
const codec = @import("codec.zig");
const limits = @import("limits.zig");
const protocol = @import("protocol.zig");

/// Diagnostic package version; capability membership is the only authority.
pub const gitframe_version = "0.0.0";

const v1 = [_]u16{1};

/// Exact cumulative list for the protocol-foundation slice.
pub const foundation_capabilities = [_]protocol.Capability{
    .{ .name = "committed-review.artifact", .versions = &v1 },
    .{ .name = "committed-review.projection", .versions = &v1 },
    .{ .name = "committed-review.target", .versions = &v1 },
    .{ .name = "review-store.prepare", .versions = &v1 },
    .{ .name = "review-store.publish", .versions = &v1 },
};

pub const CommandOutput = struct {
    exit_code: u8,
    bytes: []u8,

    pub fn deinit(self: *CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const invalid_arguments =
    "{\"schema_version\":1,\"status\":\"error\",\"error\":{\"code\":\"invalid_arguments\",\"message\":\"review-capabilities accepts no arguments\"}}\n";
const internal_error =
    "{\"schema_version\":1,\"status\":\"error\",\"error\":{\"code\":\"internal_error\",\"message\":\"review-capabilities could not complete\"}}\n";

/// Build one bounded terminal without repository, config, Store, TUI, or
/// installation access. `arguments` starts after the command token.
pub fn executeAlloc(allocator: std.mem.Allocator, arguments: []const []const u8) std.mem.Allocator.Error!CommandOutput {
    if (arguments.len != 0) {
        return .{ .exit_code = 2, .bytes = try allocator.dupe(u8, invalid_arguments) };
    }
    const response: protocol.CapabilityResponse = .{
        .schema_version = limits.schema_version,
        .status = .ok,
        .gitframe_version = gitframe_version,
        .capabilities = &foundation_capabilities,
    };
    const bytes = codec.writeCapabilityResponseAlloc(allocator, &response) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .exit_code = 70, .bytes = try allocator.dupe(u8, internal_error) },
    };
    return .{ .exit_code = 0, .bytes = bytes };
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    arguments: []const []const u8,
    stdout_file: std.Io.File,
) !u8 {
    var output = executeAlloc(allocator, arguments) catch {
        var emergency_buffer: [256]u8 = undefined;
        var emergency = stdout_file.writerStreaming(io, &emergency_buffer);
        try emergency.interface.writeAll(internal_error);
        try emergency.interface.flush();
        return 70;
    };
    defer output.deinit(allocator);

    var buffer: [4096]u8 = undefined;
    var writer = stdout_file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(output.bytes);
    try writer.interface.flush();
    return output.exit_code;
}

fn readFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "testdata/ai-review-producer-v1/protocol/{s}", .{name});
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limits.max_capabilities_bytes));
}

test "AI review protocol capabilities command emits the exact honest foundation list" {
    var output = try executeAlloc(std.testing.allocator, &.{});
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    const expected = try readFixture(std.testing.allocator, "capabilities.json");
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, output.bytes);
    try std.testing.expectEqual(@as(u8, '\n'), output.bytes[output.bytes.len - 1]);
    try std.testing.expect(std.mem.indexOfScalar(u8, output.bytes[0 .. output.bytes.len - 1], '\n') == null);

    var parsed = try protocol.CapabilityResponse.parseStrict(std.testing.allocator, output.bytes);
    defer parsed.deinit();
    try protocol.requireCapabilities(&parsed.value, &.{
        .{ .name = "committed-review.artifact", .version = 1 },
        .{ .name = "committed-review.projection", .version = 1 },
        .{ .name = "committed-review.target", .version = 1 },
        .{ .name = "review-store.prepare", .version = 1 },
        .{ .name = "review-store.publish", .version = 1 },
    });
    try std.testing.expectError(
        error.IncompatibleCapabilities,
        protocol.requireCapabilities(&parsed.value, &.{.{ .name = "ai-review.input", .version = 1 }}),
    );
}

test "AI review protocol capabilities command rejects every argument without fallback" {
    var output = try executeAlloc(std.testing.allocator, &.{"--help"});
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), output.exit_code);
    const expected = try readFixture(std.testing.allocator, "capabilities-invalid-arguments.json");
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, output.bytes);
}

test "AI review protocol diagnostic version matches the package manifest" {
    const manifest = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig.zon",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(manifest);
    const declaration = try std.fmt.allocPrint(std.testing.allocator, ".version = \"{s}\"", .{gitframe_version});
    defer std.testing.allocator.free(declaration);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, manifest, declaration));
}
