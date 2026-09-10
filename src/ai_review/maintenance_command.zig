//! Manual maintenance process adapter. Store authority stays in store_service.
const std = @import("std");
const review = @import("../committed_review.zig");
const service = @import("store_service.zig");

const Request = struct {
    operation: union(enum) { delete: review.ReviewId, cleanup_trash },
    yes: bool,
};

fn parse(arguments: []const []const u8) error{InvalidArguments}!Request {
    if (arguments.len == 2 and std.mem.eql(u8, arguments[0], "cleanup-trash") and std.mem.eql(u8, arguments[1], "--yes"))
        return .{ .operation = .cleanup_trash, .yes = true };
    if (arguments.len < 2 or arguments.len > 3 or !std.mem.eql(u8, arguments[0], "delete")) return error.InvalidArguments;
    if (arguments.len == 3 and !std.mem.eql(u8, arguments[2], "--yes")) return error.InvalidArguments;
    const id = review.ReviewId.parse(arguments[1]) catch return error.InvalidArguments;
    return .{ .operation = .{ .delete = id }, .yes = arguments.len == 3 };
}

const Terminal = struct {
    status: enum { deleted, cleaned, canceled, stopped, @"error" },
    code: ?[]const u8 = null,
    review_id: ?[36]u8 = null,
    cleanup_pending: ?bool = null,
    cleaned: ?usize = null,
    failed: ?usize = null,
    unprocessed: ?usize = null,

    fn failure(reason: service.MaintenanceFailure) Terminal {
        return .{ .status = .@"error", .code = @tagName(reason) };
    }

    fn exitCode(self: Terminal) u8 {
        if (self.status != .@"error" and self.status != .stopped) return 0;
        const code = self.code orelse return 74;
        if (std.mem.eql(u8, code, "invalid_arguments") or std.mem.eql(u8, code, "confirmation_required")) return 64;
        if (std.mem.eql(u8, code, "run_invalid") or std.mem.eql(u8, code, "binding_changed")) return 65;
        if (std.mem.eql(u8, code, "not_found")) return 66;
        if (std.mem.eql(u8, code, "unsupported")) return 69;
        if (std.mem.eql(u8, code, "out_of_memory")) return 70;
        if (std.mem.eql(u8, code, "conflict")) return 75;
        if (std.mem.eql(u8, code, "permission_denied")) return 77;
        if (std.mem.eql(u8, code, "unfinished")) return 64;
        return 74;
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, environment: ?*std.process.Environ.Map, arguments: []const []const u8, stdin: std.Io.File, stdout: std.Io.File, stderr: std.Io.File) !u8 {
    const terminal = execute(allocator, io, environment, arguments, stdin, stderr) catch |err| Terminal{
        .status = .@"error",
        .code = if (err == error.OutOfMemory) "out_of_memory" else "io_failed",
    };
    var buffer: [1024]u8 = undefined;
    var writer = stdout.writerStreaming(io, &buffer);
    try writeTerminal(&writer.interface, terminal);
    try writer.interface.flush();
    return terminal.exitCode();
}

fn execute(allocator: std.mem.Allocator, io: std.Io, environment: ?*std.process.Environ.Map, arguments: []const []const u8, stdin: std.Io.File, stderr: std.Io.File) !Terminal {
    const request = parse(arguments) catch {
        var buffer: [512]u8 = undefined;
        var writer = stderr.writerStreaming(io, &buffer);
        try writer.interface.writeAll("Usage: gitframe ai-review delete <review-id> [--yes]\n       gitframe ai-review cleanup-trash --yes\n");
        try writer.interface.flush();
        return .{ .status = .@"error", .code = "invalid_arguments" };
    };
    if (!request.yes and !try stdin.isTty(io)) return .{ .status = .@"error", .code = "confirmation_required" };
    const path = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    if (request.operation == .cleanup_trash) {
        return cleanupTerminal(try service.cleanupFromPath(allocator, io, environment, path));
    }
    const id = request.operation.delete;
    var result = try service.previewDelete(allocator, io, environment, path, id);
    defer result.deinit(allocator);
    const preview = switch (result) {
        .preview => |*value| value,
        .failure => |failure| return Terminal.failure(failure),
    };
    var buffer: [2048]u8 = undefined;
    var writer = stderr.writerStreaming(io, &buffer);
    try writeSummary(&writer.interface, preview);
    if (!request.yes) try writer.interface.writeAll("Delete this Run? [y/yes, default No]: ");
    try writer.interface.flush();
    if (!request.yes and !try confirm(io, stdin)) return .{ .status = .canceled, .review_id = id.canonical() };
    // All allocation/formatting needed for confirmation precedes the mutation.
    // The terminal is fixed-size and preserves success even if cleanup failed.
    return deleteTerminal(id, try service.deleteFromPath(allocator, io, environment, path, .{
        .store = preview.store,
        .review_id = id,
        .artifacts = preview.exact.artifacts,
        .allow_unfinished = true,
    }));
}

fn deleteTerminal(id: review.ReviewId, result: service.DeleteResult) Terminal {
    return switch (result) {
        .failure => |failure| Terminal.failure(failure),
        .deleted => |cleanup| .{
            .status = .deleted,
            .review_id = id.canonical(),
            .cleanup_pending = cleanup == .pending,
            .code = if (cleanup == .pending) @tagName(cleanup.pending) else null,
        },
    };
}

fn cleanupTerminal(result: service.CleanupResult) Terminal {
    return switch (result) {
        .cleaned => |count| .{ .status = .cleaned, .cleaned = count, .failed = 0, .unprocessed = 0 },
        .failure => |failure| Terminal.failure(failure),
        .stopped => |value| .{ .status = .stopped, .cleaned = value.cleaned, .failed = value.failed, .unprocessed = value.unprocessed, .code = @tagName(value.failure) },
    };
}

fn writeTerminal(writer: *std.Io.Writer, terminal: Terminal) !void {
    try std.json.Stringify.value(terminal, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
}

fn writeSummary(writer: *std.Io.Writer, preview: *const service.DeletePreview) !void {
    const identity = &preview.exact.identity;
    try writer.print("Review: {s}\nCreated: {s}\nProducer: ", .{ preview.exact.review_id.canonical(), identity.created_at });
    try writeEscaped(writer, identity.producer_name);
    if (identity.producer_model) |model| {
        try writer.writeAll(" / ");
        try writeEscaped(writer, model);
    }
    try writer.print("\nTarget: {s}..{s}\nFindings: {d}\nState: {s}\n", .{ identity.target.base_oid.slice(), identity.target.head_oid.slice(), identity.finding_count, @tagName(preview.status) });
    if (preview.exact.artifacts.draft_state == .invalid) try writer.writeAll("Warning: retained draft is invalid.\n");
    if (preview.status == .new or preview.status == .draft)
        try writer.writeAll("WARNING: This Run is unfinished. Deletion permanently removes its review work.\n");
}

fn writeEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    for (value[0..@min(value.len, 256)]) |byte| {
        if (byte >= 32 and byte <= 126 and byte != '\\') try writer.writeByte(byte) else try writer.print("\\x{x:0>2}", .{byte});
    }
    if (value.len > 256) try writer.writeAll("...");
}

fn confirmed(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "yes");
}

fn confirm(io: std.Io, input: std.Io.File) !bool {
    var line: [64]u8 = undefined;
    var used: usize = 0;
    while (used < line.len) {
        var byte: [1]u8 = undefined;
        const count = input.readStreaming(io, &.{&byte}) catch |err| switch (err) {
            error.EndOfStream => return false,
            else => return err,
        };
        if (count == 0) return false;
        if (byte[0] == 27) return false;
        if (byte[0] == '\n') return confirmed(line[0..used]);
        line[used] = byte[0];
        used += 1;
    }
    return false;
}

test "review run maintenance arguments and confirmation are explicit and bounded" {
    const id = "123e4567-e89b-42d3-a456-426614174000";
    try std.testing.expect(!(try parse(&.{ "delete", id })).yes);
    try std.testing.expect((try parse(&.{ "delete", id, "--yes" })).yes);
    try std.testing.expect((try parse(&.{ "cleanup-trash", "--yes" })).operation == .cleanup_trash);
    for ([_][]const []const u8{ &.{}, &.{"cleanup-trash"}, &.{ "delete", "../x", "--yes" }, &.{ "delete", id, "--force" }, &.{ "prune", "--yes" }, &.{ "delete", id, "--yes", "--yes" } }) |args| try std.testing.expectError(error.InvalidArguments, parse(args));
    for ([_][]const u8{ "", "Y", "YES", "no", "yes please", "y\x1b", "y\x00" }) |line| try std.testing.expect(!confirmed(line));
    try std.testing.expect(confirmed("yes"));
    try std.testing.expect(confirmed(" y\r"));
}

test "review run maintenance preserves deletion cleanup and failure terminals" {
    const id = try review.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000");
    const cases = [_]struct { reason: service.MaintenanceFailure, code: u8 }{
        .{ .reason = .not_found, .code = 66 }, .{ .reason = .conflict, .code = 75 }, .{ .reason = .unfinished, .code = 64 }, .{ .reason = .binding_changed, .code = 65 }, .{ .reason = .run_invalid, .code = 65 }, .{ .reason = .permission_denied, .code = 77 }, .{ .reason = .io_failed, .code = 74 }, .{ .reason = .store_unavailable, .code = 74 }, .{ .reason = .unsupported, .code = 69 },
    };
    for (cases) |case| {
        const failed = deleteTerminal(id, .{ .failure = case.reason });
        try std.testing.expectEqual(case.code, failed.exitCode());
        const pending = deleteTerminal(id, .{ .deleted = .{ .pending = case.reason } });
        try std.testing.expectEqual(@as(u8, 0), pending.exitCode());
        try std.testing.expect(pending.cleanup_pending.?);
        var storage: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&storage);
        try writeTerminal(&writer, pending);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("deleted", parsed.value.object.get("status").?.string);
        try std.testing.expectEqualStrings(@tagName(case.reason), parsed.value.object.get("code").?.string);
    }
    const stopped = cleanupTerminal(.{ .stopped = .{ .cleaned = 2, .unprocessed = 3, .name = @splat('a'), .failure = .permission_denied } });
    try std.testing.expectEqual(@as(u8, 77), stopped.exitCode());
    try std.testing.expectEqual(@as(usize, 2), stopped.cleaned.?);
    try std.testing.expectEqual(@as(usize, 3), stopped.unprocessed.?);
}

test "review run maintenance input EOF escape length and noninteractive confirmation never apply" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]struct { bytes: []const u8, yes: bool }{
        .{ .bytes = "y\n", .yes = true },              .{ .bytes = "yes\n", .yes = true },
        .{ .bytes = "y", .yes = false },               .{ .bytes = "", .yes = false },
        .{ .bytes = "\x1b\n", .yes = false },          .{ .bytes = "\n", .yes = false },
        .{ .bytes = "y" ** 64 ++ "\n", .yes = false },
    }) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = case.bytes });
        var input = try tmp.dir.openFile(io, "input", .{});
        defer input.close(io);
        try std.testing.expectEqual(case.yes, try confirm(io, input));
    }
    var input = try tmp.dir.openFile(io, "input", .{});
    defer input.close(io);
    var diagnostics = try tmp.dir.createFile(io, "stderr", .{});
    defer diagnostics.close(io);
    const terminal = try execute(allocator, io, null, &.{ "delete", "123e4567-e89b-42d3-a456-426614174000" }, input, diagnostics);
    try std.testing.expectEqualStrings("confirmation_required", terminal.code.?);
    try std.testing.expectEqual(@as(u8, 64), terminal.exitCode());
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeEscaped(&writer, "model\x1b]52;payload\x07\n");
    try std.testing.expectEqualStrings("model\\x1b]52;payload\\x07\\x0a", writer.buffered());
}
