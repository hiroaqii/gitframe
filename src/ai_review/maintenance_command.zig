//! Manual maintenance process adapter. Store authority stays in store_service.
const std = @import("std");
const review = @import("../committed_review.zig");
const service = @import("store_service.zig");

const PruneMode = enum { dry_run, apply };

const PrunePolicy = struct {
    older_than_days: ?u32 = null,
    keep_last: ?usize = null,
    include_unfinished: bool = false,
    mode: PruneMode = .dry_run,
};

const Request = struct {
    operation: union(enum) { delete: review.ReviewId, cleanup_trash, prune: PrunePolicy },
    yes: bool,
};

fn parse(arguments: []const []const u8) error{InvalidArguments}!Request {
    if (arguments.len == 2 and std.mem.eql(u8, arguments[0], "cleanup-trash") and std.mem.eql(u8, arguments[1], "--yes"))
        return .{ .operation = .cleanup_trash, .yes = true };
    if (arguments.len != 0 and std.mem.eql(u8, arguments[0], "prune"))
        return .{ .operation = .{ .prune = try parsePrune(arguments[1..]) }, .yes = true };
    if (arguments.len >= 2 and arguments.len <= 3 and std.mem.eql(u8, arguments[0], "delete")) {
        if (arguments.len == 3 and !std.mem.eql(u8, arguments[2], "--yes")) return error.InvalidArguments;
        const id = review.ReviewId.parse(arguments[1]) catch return error.InvalidArguments;
        return .{ .operation = .{ .delete = id }, .yes = arguments.len == 3 };
    }
    return error.InvalidArguments;
}

fn parsePrune(arguments: []const []const u8) error{InvalidArguments}!PrunePolicy {
    var policy: PrunePolicy = .{};
    var seen_include_unfinished = false;
    var seen_mode = false;
    var index: usize = 0;
    while (index < arguments.len) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--older-than")) {
            if (policy.older_than_days != null or index + 1 == arguments.len) return error.InvalidArguments;
            policy.older_than_days = try parseDays(arguments[index + 1]);
            index += 2;
        } else if (std.mem.eql(u8, argument, "--keep-last")) {
            if (policy.keep_last != null or index + 1 == arguments.len) return error.InvalidArguments;
            const digits = arguments[index + 1];
            if (digits.len == 0) return error.InvalidArguments;
            for (digits) |byte| if (byte < '0' or byte > '9') return error.InvalidArguments;
            const value = std.fmt.parseInt(usize, digits, 10) catch return error.InvalidArguments;
            if (value == 0 or value > service.max_run_candidates) return error.InvalidArguments;
            policy.keep_last = value;
            index += 2;
        } else if (std.mem.eql(u8, argument, "--include-unfinished")) {
            if (seen_include_unfinished) return error.InvalidArguments;
            seen_include_unfinished = true;
            policy.include_unfinished = true;
            index += 1;
        } else if (std.mem.eql(u8, argument, "--dry-run") or std.mem.eql(u8, argument, "--apply")) {
            if (seen_mode) return error.InvalidArguments;
            seen_mode = true;
            policy.mode = if (std.mem.eql(u8, argument, "--apply")) .apply else .dry_run;
            index += 1;
        } else return error.InvalidArguments;
    }
    if (policy.older_than_days == null and policy.keep_last == null) return error.InvalidArguments;
    return policy;
}

fn parseDays(value: []const u8) error{InvalidArguments}!u32 {
    if (value.len < 2 or value[value.len - 1] != 'd') return error.InvalidArguments;
    const digits = value[0 .. value.len - 1];
    if (digits.len == 0) return error.InvalidArguments;
    for (digits) |byte| if (byte < '0' or byte > '9') return error.InvalidArguments;
    const days = std.fmt.parseInt(u32, digits, 10) catch return error.InvalidArguments;
    if (days == 0) return error.InvalidArguments;
    _ = std.math.mul(i64, @as(i64, days), std.time.s_per_day) catch return error.InvalidArguments;
    return days;
}

const Terminal = struct {
    status: enum { deleted, cleaned, prune_preview, pruned, canceled, stopped, @"error" },
    code: ?[]const u8 = null,
    review_id: ?[36]u8 = null,
    cleanup_pending: ?std.json.Value = null,
    cleaned: ?usize = null,
    failed: ?usize = null,
    unprocessed: ?usize = null,
    selected: ?usize = null,
    selected_logical_bytes: ?u64 = null,
    skipped: ?usize = null,
    orphan_temp: ?usize = null,
    deleted: ?usize = null,
    deleted_logical_bytes: ?u64 = null,

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
    return executeWithClock(allocator, io, environment, arguments, stdin, stderr, .{ .sample = sampleRealClock });
}

const Clock = struct {
    context: ?*anyopaque = null,
    sample: *const fn (?*anyopaque, std.Io) ?i64,
};

fn executeWithClock(allocator: std.mem.Allocator, io: std.Io, environment: ?*std.process.Environ.Map, arguments: []const []const u8, stdin: std.Io.File, stderr: std.Io.File, clock: Clock) !Terminal {
    const request = parse(arguments) catch {
        var buffer: [512]u8 = undefined;
        var writer = stderr.writerStreaming(io, &buffer);
        try writer.interface.writeAll(
            "Usage: gitframe ai-review prune --older-than 90d --dry-run\n" ++
                "       gitframe ai-review prune [--older-than <Nd>] [--keep-last <N>] [--include-unfinished] [--dry-run | --apply]\n" ++
                "       gitframe ai-review delete <review-id> [--yes]\n" ++
                "       gitframe ai-review cleanup-trash --yes\n",
        );
        try writer.interface.flush();
        return .{ .status = .@"error", .code = "invalid_arguments" };
    };
    const path = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    if (request.operation == .prune)
        return executePrune(allocator, io, environment, path, request.operation.prune, stderr, clock);
    if (!request.yes and !try stdin.isTty(io)) return .{ .status = .@"error", .code = "confirmation_required" };
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

const PruneSelection = struct {
    rows: []*const service.MaintenanceRow,
    excluded: []*const service.MaintenanceRow,
    logical_bytes: u64,

    fn deinit(self: *PruneSelection, allocator: std.mem.Allocator) void {
        allocator.free(self.excluded);
        allocator.free(self.rows);
        self.* = undefined;
    }
};

fn executePrune(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*std.process.Environ.Map,
    repository_path: []const u8,
    policy: PrunePolicy,
    stderr: std.Io.File,
    clock: Clock,
) !Terminal {
    return executePruneWithDelete(allocator, io, environment, repository_path, policy, stderr, clock, .{});
}

const PruneDelete = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, std.mem.Allocator, std.Io, ?*std.process.Environ.Map, []const u8, service.DeleteRequest) anyerror!service.DeleteResult = callDeleteFromPath,
};

fn callDeleteFromPath(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*std.process.Environ.Map,
    repository_path: []const u8,
    request: service.DeleteRequest,
) !service.DeleteResult {
    return service.deleteFromPath(allocator, io, environment, repository_path, request);
}

fn executePruneWithDelete(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*std.process.Environ.Map,
    repository_path: []const u8,
    policy: PrunePolicy,
    stderr: std.Io.File,
    clock: Clock,
    delete: PruneDelete,
) !Terminal {
    const evaluation_unix = if (policy.older_than_days != null)
        clock.sample(clock.context, io) orelse return Terminal.failure(.io_failed)
    else
        null;
    var scanned = try service.scanMaintenanceFromPath(allocator, io, environment, repository_path);
    defer scanned.deinit(allocator);
    const catalog = switch (scanned) {
        .unbound, .bound_empty => return pruneTerminal(policy.mode, 0, 0, 0, 0),
        .failure => |failure| return Terminal.failure(failure),
        .catalog => |*value| value,
    };
    var selection = selectPrune(allocator, catalog.rows, policy, evaluation_unix) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => return Terminal.failure(.run_invalid),
    };
    defer selection.deinit(allocator);
    const skipped = std.math.add(usize, catalog.skipped_count, selection.excluded.len) catch
        return Terminal.failure(.run_invalid);

    var buffer: [4096]u8 = undefined;
    var writer = stderr.writerStreaming(io, &buffer);
    for (selection.rows) |row| try writePruneCandidate(&writer.interface, row);
    for (selection.excluded) |row| try writePruneExclusion(&writer.interface, row);
    for (catalog.diagnostics) |diagnostic| {
        try writer.interface.print("Diagnostic {s}: ", .{@tagName(diagnostic.kind)});
        try writeEscaped(&writer.interface, diagnostic.text);
        try writer.interface.writeByte('\n');
    }
    try writer.interface.flush();

    if (policy.mode == .dry_run)
        return pruneTerminal(.dry_run, selection.rows.len, selection.logical_bytes, skipped, catalog.orphan_count);

    var deleted: usize = 0;
    var deleted_logical_bytes: u64 = 0;
    var cleanup_pending: usize = 0;
    for (selection.rows, 0..) |row, index| {
        const result = delete.call(delete.context, allocator, io, environment, repository_path, .{
            .store = catalog.store,
            .review_id = row.review_id,
            .artifacts = row.artifacts,
            .allow_unfinished = policy.include_unfinished,
        }) catch return stoppedPrune(
            "out_of_memory",
            &selection,
            skipped,
            catalog.orphan_count,
            deleted,
            deleted_logical_bytes,
            cleanup_pending,
            index,
        );
        switch (result) {
            .failure => |failure| return stoppedPrune(
                @tagName(failure),
                &selection,
                skipped,
                catalog.orphan_count,
                deleted,
                deleted_logical_bytes,
                cleanup_pending,
                index,
            ),
            .deleted => |cleanup| {
                deleted += 1;
                deleted_logical_bytes = std.math.add(u64, deleted_logical_bytes, row.logical_bytes) catch unreachable;
                if (cleanup == .pending) cleanup_pending += 1;
            },
        }
    }
    return .{
        .status = .pruned,
        .selected = selection.rows.len,
        .selected_logical_bytes = selection.logical_bytes,
        .skipped = skipped,
        .orphan_temp = catalog.orphan_count,
        .deleted = deleted,
        .deleted_logical_bytes = deleted_logical_bytes,
        .cleanup_pending = .{ .integer = @intCast(cleanup_pending) },
        .failed = 0,
        .unprocessed = 0,
    };
}

fn stoppedPrune(
    code: []const u8,
    selection: *const PruneSelection,
    skipped: usize,
    orphan_temp: usize,
    deleted: usize,
    deleted_logical_bytes: u64,
    cleanup_pending: usize,
    failed_index: usize,
) Terminal {
    return .{
        .status = .stopped,
        .code = code,
        .selected = selection.rows.len,
        .selected_logical_bytes = selection.logical_bytes,
        .skipped = skipped,
        .orphan_temp = orphan_temp,
        .deleted = deleted,
        .deleted_logical_bytes = deleted_logical_bytes,
        .cleanup_pending = .{ .integer = @intCast(cleanup_pending) },
        .failed = 1,
        .unprocessed = selection.rows.len - failed_index - 1,
    };
}

fn pruneTerminal(mode: PruneMode, selected: usize, logical_bytes: u64, skipped: usize, orphan_temp: usize) Terminal {
    return .{
        .status = if (mode == .dry_run) .prune_preview else .pruned,
        .selected = selected,
        .selected_logical_bytes = logical_bytes,
        .skipped = skipped,
        .orphan_temp = orphan_temp,
        .deleted = if (mode == .apply) 0 else null,
        .deleted_logical_bytes = if (mode == .apply) 0 else null,
        .cleanup_pending = if (mode == .apply) .{ .integer = 0 } else null,
        .failed = if (mode == .apply) 0 else null,
        .unprocessed = if (mode == .apply) 0 else null,
    };
}

fn selectPrune(
    allocator: std.mem.Allocator,
    rows: []const service.MaintenanceRow,
    policy: PrunePolicy,
    evaluation_unix: ?i64,
) (std.mem.Allocator.Error || error{Overflow})!PruneSelection {
    const cutoff = if (policy.older_than_days) |days| blk: {
        const evaluation = evaluation_unix orelse return error.Overflow;
        const seconds = std.math.mul(i64, @as(i64, days), std.time.s_per_day) catch return error.Overflow;
        break :blk std.math.sub(i64, evaluation, seconds) catch return error.Overflow;
    } else null;
    var eligible: std.ArrayList(*const service.MaintenanceRow) = .empty;
    defer eligible.deinit(allocator);
    var excluded: std.ArrayList(*const service.MaintenanceRow) = .empty;
    defer excluded.deinit(allocator);
    for (rows) |*row| {
        if (!deleteAdmissible(row)) {
            try excluded.append(allocator, row);
            continue;
        }
        if (!policy.include_unfinished and (row.status == .new or row.status == .draft)) continue;
        try eligible.append(allocator, row);
    }
    std.mem.sort(*const service.MaintenanceRow, eligible.items, {}, maintenanceRowLessThan);

    var selected_count: usize = 0;
    var logical_bytes: u64 = 0;
    for (eligible.items, 0..) |row, rank| {
        const age_match = cutoff == null or row.created_at_unix < cutoff.?;
        const retention_match = policy.keep_last == null or rank >= policy.keep_last.?;
        if (!age_match or !retention_match) continue;
        eligible.items[selected_count] = row;
        selected_count += 1;
        logical_bytes = std.math.add(u64, logical_bytes, row.logical_bytes) catch return error.Overflow;
    }
    eligible.items = eligible.items[0..selected_count];
    const selected = try eligible.toOwnedSlice(allocator);
    errdefer allocator.free(selected);
    return .{
        .rows = selected,
        .excluded = try excluded.toOwnedSlice(allocator),
        .logical_bytes = logical_bytes,
    };
}

fn deleteAdmissible(row: *const service.MaintenanceRow) bool {
    return row.artifacts.draft_state != .unsafe and
        !(row.artifacts.draft_state == .invalid and row.artifacts.draft_digest == null);
}

fn maintenanceRowLessThan(_: void, left: *const service.MaintenanceRow, right: *const service.MaintenanceRow) bool {
    if (left.created_at_unix != right.created_at_unix) return left.created_at_unix > right.created_at_unix;
    const left_text = left.review_id.canonical();
    const right_text = right.review_id.canonical();
    return std.mem.lessThan(u8, &left_text, &right_text);
}

fn writePruneCandidate(writer: *std.Io.Writer, row: *const service.MaintenanceRow) !void {
    try writer.print("Candidate {s} {s} ", .{ row.review_id.canonical(), &row.created_at });
    try writeEscaped(writer, row.producer_name);
    if (row.producer_model) |model| {
        try writer.writeAll(" / ");
        try writeEscaped(writer, model);
    }
    try writer.print(" {s}..{s} state={s} findings={d} logical-bytes={d}\n", .{
        row.target.base_oid.slice()[0..12],
        row.target.head_oid.slice()[0..12],
        @tagName(row.status),
        row.finding_count,
        row.logical_bytes,
    });
}

fn writePruneExclusion(writer: *std.Io.Writer, row: *const service.MaintenanceRow) !void {
    const reason: []const u8 = if (row.artifacts.draft_state == .unsafe)
        "unsafe retained draft"
    else
        "unreadable retained draft";
    try writer.print("Skipped {s}: {s}\n", .{ row.review_id.canonical(), reason });
}

fn sampleRealClock(_: ?*anyopaque, io: std.Io) ?i64 {
    const resolution = std.Io.Clock.real.resolution(io) catch return null;
    if (resolution.nanoseconds == 0) return null;
    const timestamp = std.Io.Clock.real.now(io);
    return std.math.cast(i64, @divFloor(timestamp.nanoseconds, std.time.ns_per_s));
}

fn deleteTerminal(id: review.ReviewId, result: service.DeleteResult) Terminal {
    return switch (result) {
        .failure => |failure| Terminal.failure(failure),
        .deleted => |cleanup| .{
            .status = .deleted,
            .review_id = id.canonical(),
            .cleanup_pending = .{ .bool = cleanup == .pending },
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
    const default_prune = (try parse(&.{ "prune", "--older-than", "90d" })).operation.prune;
    try std.testing.expectEqual(@as(?u32, 90), default_prune.older_than_days);
    try std.testing.expectEqual(PruneMode.dry_run, default_prune.mode);
    const apply_prune = (try parse(&.{ "prune", "--keep-last", "12", "--include-unfinished", "--apply" })).operation.prune;
    try std.testing.expectEqual(@as(?usize, 12), apply_prune.keep_last);
    try std.testing.expect(apply_prune.include_unfinished);
    try std.testing.expectEqual(PruneMode.apply, apply_prune.mode);
    for ([_][]const []const u8{
        &.{},
        &.{"cleanup-trash"},
        &.{ "delete", "../x", "--yes" },
        &.{ "delete", id, "--force" },
        &.{ "prune", "--yes" },
        &.{ "prune", "--include-unfinished" },
        &.{ "prune", "--older-than" },
        &.{ "prune", "--older-than", "0d" },
        &.{ "prune", "--older-than", "+1d" },
        &.{ "prune", "--older-than", "1D" },
        &.{ "prune", "--older-than", "4294967296d" },
        &.{ "prune", "--keep-last", "0" },
        &.{ "prune", "--keep-last", "+1" },
        &.{ "prune", "--keep-last", "513" },
        &.{ "prune", "--keep-last", "1", "--keep-last", "2" },
        &.{ "prune", "--older-than", "1d", "--dry-run", "--apply" },
        &.{ "delete", id, "--yes", "--yes" },
    }) |args| try std.testing.expectError(error.InvalidArguments, parse(args));
    for ([_][]const u8{ "", "Y", "YES", "no", "yes please", "y\x1b", "y\x00" }) |line| try std.testing.expect(!confirmed(line));
    try std.testing.expect(confirmed("yes"));
    try std.testing.expect(confirmed(" y\r"));
}

test "review run maintenance prune selection is bounded deterministic and delete admissible" {
    const allocator = std.testing.allocator;
    const digest = review.Sha256Digest.hash("artifact");
    const rows = [_]service.MaintenanceRow{
        try testMaintenanceRow("123e4567-e89b-42d3-a456-426614174000", 200_000, .approved, .valid, digest, 10),
        try testMaintenanceRow("223e4567-e89b-42d3-a456-426614174000", 195_000, .approved, .unsafe, null, 20),
        try testMaintenanceRow("323e4567-e89b-42d3-a456-426614174000", 190_000, .approved, .invalid, null, 30),
        try testMaintenanceRow("423e4567-e89b-42d3-a456-426614174000", 170_000, .needs_changes, .invalid, digest, 40),
        try testMaintenanceRow("723e4567-e89b-42d3-a456-426614174000", 170_000, .canceled, .absent, null, 70),
        try testMaintenanceRow("823e4567-e89b-42d3-a456-426614174000", 113_600, .approved, .absent, null, 80),
        try testMaintenanceRow("523e4567-e89b-42d3-a456-426614174000", 100_000, .approved, .absent, null, 50),
        try testMaintenanceRow("623e4567-e89b-42d3-a456-426614174000", 90_000, .draft, .valid, digest, 60),
    };

    var keep = try selectPrune(allocator, &rows, .{ .keep_last = 1 }, null);
    defer keep.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), keep.rows.len);
    try std.testing.expectEqualStrings("423e4567-e89b-42d3-a456-426614174000", &keep.rows[0].review_id.canonical());
    try std.testing.expectEqualStrings("723e4567-e89b-42d3-a456-426614174000", &keep.rows[1].review_id.canonical());
    try std.testing.expectEqual(@as(u64, 240), keep.logical_bytes);
    try std.testing.expectEqual(@as(usize, 2), keep.excluded.len);

    var older = try selectPrune(allocator, &rows, .{ .older_than_days = 1 }, 200_000);
    defer older.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), older.rows.len);
    try std.testing.expectEqualStrings("523e4567-e89b-42d3-a456-426614174000", &older.rows[0].review_id.canonical());

    var combined = try selectPrune(allocator, &rows, .{ .older_than_days = 1, .keep_last = 1 }, 200_000);
    defer combined.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), combined.rows.len);
    try std.testing.expectEqual(@as(u64, 50), combined.logical_bytes);

    var unfinished = try selectPrune(allocator, &rows, .{ .older_than_days = 1, .include_unfinished = true }, 200_000);
    defer unfinished.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), unfinished.rows.len);
    try std.testing.expectEqualStrings("623e4567-e89b-42d3-a456-426614174000", &unfinished.rows[1].review_id.canonical());

    var display_row = rows[3];
    display_row.producer_name = @constCast("producer\x1b\n");
    display_row.producer_model = @constCast("model");
    var display_storage: [2048]u8 = undefined;
    var display_writer: std.Io.Writer = .fixed(&display_storage);
    try writePruneCandidate(&display_writer, &display_row);
    try std.testing.expect(std.mem.indexOf(u8, display_writer.buffered(), "producer\\x1b\\x0a / model") != null);
    try std.testing.expect(std.mem.indexOf(u8, display_writer.buffered(), "logical-bytes=40") != null);

    const stopped = stoppedPrune("conflict", &keep, 2, 1, 1, 40, 1, 1);
    try std.testing.expectEqual(@as(u8, 75), stopped.exitCode());
    try std.testing.expectEqual(@as(?usize, 1), stopped.deleted);
    try std.testing.expectEqual(@as(?usize, 2), stopped.unprocessed);
    try std.testing.expectEqual(@as(i64, 1), stopped.cleanup_pending.?.integer);
    var terminal_storage: [1024]u8 = undefined;
    var terminal_writer: std.Io.Writer = .fixed(&terminal_storage);
    try writeTerminal(&terminal_writer, pruneTerminal(.apply, 0, 0, 2, 1));
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, terminal_writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("pruned", parsed.value.object.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("cleanup_pending").?.integer);
}

fn testMaintenanceRow(
    id: []const u8,
    created_at_unix: i64,
    status: service.RunSummaryStatus,
    draft_state: @FieldType(service.ArtifactSnapshot, "draft_state"),
    draft_digest: ?review.Sha256Digest,
    logical_bytes: u64,
) !service.MaintenanceRow {
    const object_id = try review.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const digest = review.Sha256Digest.hash("artifact");
    return .{
        .review_id = try review.ReviewId.parse(id),
        .target = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = object_id,
            .head_oid = object_id,
            .diff_base_oid = object_id,
        },
        .status = status,
        .created_at = "2026-09-11T00:00:00Z".*,
        .created_at_unix = created_at_unix,
        .producer_name = @constCast("test-producer"),
        .producer_model = null,
        .finding_count = 1,
        .artifacts = .{
            .manifest_digest = digest,
            .findings_digest = digest,
            .draft_state = draft_state,
            .draft_digest = draft_digest,
            .result_digest = digest,
        },
        .logical_bytes = logical_bytes,
    };
}

test "review run maintenance prune command uses one disposable Store authority" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "repo", .fromMode(0o700));
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try runPruneTestGit(io, repo, &.{ "git", "init", "--initial-branch=main" });
    const repository_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repository_path);

    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    const store_path = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(store_path);
    try tmp.dir.createDir(io, "config", .fromMode(0o700));
    try tmp.dir.createDir(io, "config/gitframe", .fromMode(0o700));
    const config_bytes = try std.fmt.allocPrint(allocator, "[ai_review]\nstore_root = \"{s}\"\n", .{store_path});
    defer allocator.free(config_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "config/gitframe/config.toml", .data = config_bytes });
    const config_home = try tmp.dir.realPathFileAlloc(io, "config", allocator);
    defer allocator.free(config_home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("XDG_CONFIG_HOME", config_home);

    const prepared = (try service.prepare(allocator, io, &environment, repository_path)).success;
    var store = try tmp.dir.openDir(io, "store", .{});
    defer store.close(io);
    const repository_name = prepared.review_repository_id.canonical();
    var locks = try store.openDir(io, ".locks", .{});
    defer locks.close(io);
    locks.createDir(io, &repository_name, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
    var namespace = try store.openDir(io, prepared.repository_directory_name.slice(), .{});
    defer namespace.close(io);

    const oid = try review.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    const target: review.CommittedReviewTarget = .{ .object_format = .sha1, .source_kind = .branch_range, .base_oid = oid, .head_oid = oid, .diff_base_oid = oid };
    const unsafe_id = try review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const oversized_id = try review.ReviewId.parse("323e4567-e89b-42d3-a456-426614174000");
    const malformed_id = try review.ReviewId.parse("423e4567-e89b-42d3-a456-426614174000");
    const older_id = try review.ReviewId.parse("523e4567-e89b-42d3-a456-426614174000");
    const oldest_id = try review.ReviewId.parse("623e4567-e89b-42d3-a456-426614174000");
    const unfinished_id = try review.ReviewId.parse("723e4567-e89b-42d3-a456-426614174000");
    try seedPruneTestRun(allocator, io, namespace, prepared.review_repository_id, prepared.review_id, target, "2026-08-20T09:00:00Z", .completed);
    try seedPruneTestRun(allocator, io, namespace, prepared.review_repository_id, unsafe_id, target, "2026-08-20T08:00:00Z", .unsafe_draft);
    try seedPruneTestRun(allocator, io, namespace, prepared.review_repository_id, oversized_id, target, "2026-08-20T07:00:00Z", .oversized_draft);
    try seedPruneTestRun(allocator, io, namespace, prepared.review_repository_id, malformed_id, target, "2026-08-20T06:00:00Z", .malformed_draft);
    try seedPruneTestRun(allocator, io, namespace, prepared.review_repository_id, older_id, target, "2026-08-20T05:00:00Z", .completed);
    try seedPruneTestRun(allocator, io, namespace, prepared.review_repository_id, oldest_id, target, "2026-08-20T04:00:00Z", .completed);
    try seedPruneTestRun(allocator, io, namespace, prepared.review_repository_id, unfinished_id, target, "2026-08-20T03:00:00Z", .unfinished);

    const other_repository = try review.ReviewRepositoryId.parse("823e4567-e89b-42d3-a456-426614174000");
    try store.createDir(io, &other_repository.canonical(), .fromMode(0o700));
    var other_namespace = try store.openDir(io, &other_repository.canonical(), .{});
    defer other_namespace.close(io);
    try seedPruneTestRun(allocator, io, other_namespace, other_repository, older_id, target, "2026-08-20T01:00:00Z", .completed);

    const registry_before = try store.readFileAlloc(io, "registry.json", allocator, .limited(64 * 1024));
    defer allocator.free(registry_before);
    const head_before = try repo.readFileAlloc(io, ".git/HEAD", allocator, .limited(1024));
    defer allocator.free(head_before);
    var before = try service.scanMaintenanceFromPath(allocator, io, &environment, repository_path);
    defer before.deinit(allocator);
    const expected_bytes = (try pruneTestRow(&before.catalog, malformed_id)).logical_bytes +
        (try pruneTestRow(&before.catalog, older_id)).logical_bytes +
        (try pruneTestRow(&before.catalog, oldest_id)).logical_bytes;
    const policy: PrunePolicy = .{ .older_than_days = 1, .keep_last = 1 };
    const apply_policy: PrunePolicy = .{ .older_than_days = 1, .keep_last = 1, .mode = .apply };

    var dry_clock: PruneTestClock = .{ .now = 1_800_000_000 };
    var dry_stderr = try tmp.dir.createFile(io, "dry-stderr", .{});
    const dry = try executePrune(allocator, io, &environment, repository_path, policy, dry_stderr, .{ .context = &dry_clock, .sample = PruneTestClock.sample });
    dry_stderr.close(io);
    try expectPruneTestTerminal(dry, .prune_preview, 3, expected_bytes, 2, 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), dry_clock.calls);
    const dry_output = try tmp.dir.readFileAlloc(io, "dry-stderr", allocator, .limited(64 * 1024));
    defer allocator.free(dry_output);
    try expectPruneCandidates(dry_output, &.{ malformed_id, older_id, oldest_id });
    var after_dry = try service.scanMaintenanceFromPath(allocator, io, &environment, repository_path);
    defer after_dry.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 7), after_dry.catalog.rows.len);

    var apply_clock: PruneTestClock = .{ .now = dry_clock.now };
    var apply_stderr = try tmp.dir.createFile(io, "apply-stderr", .{});
    const applied = try executePrune(allocator, io, &environment, repository_path, apply_policy, apply_stderr, .{ .context = &apply_clock, .sample = PruneTestClock.sample });
    apply_stderr.close(io);
    try expectPruneTestTerminal(applied, .pruned, 3, expected_bytes, 2, 3, expected_bytes, 0);
    try std.testing.expectEqual(@as(usize, 1), apply_clock.calls);
    const apply_output = try tmp.dir.readFileAlloc(io, "apply-stderr", allocator, .limited(64 * 1024));
    defer allocator.free(apply_output);
    try std.testing.expectEqualStrings(dry_output, apply_output);
    var after_apply = try service.scanMaintenanceFromPath(allocator, io, &environment, repository_path);
    defer after_apply.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), after_apply.catalog.rows.len);
    for ([_]review.ReviewId{ prepared.review_id, unsafe_id, oversized_id, unfinished_id }) |id| _ = try pruneTestRow(&after_apply.catalog, id);
    var other_run = try other_namespace.openDir(io, &older_id.canonical(), .{});
    other_run.close(io);

    const first_failure_id = try review.ReviewId.parse("923e4567-e89b-42d3-a456-426614174000");
    const failed_id = try review.ReviewId.parse("a23e4567-e89b-42d3-a456-426614174000");
    const unprocessed_id = try review.ReviewId.parse("b23e4567-e89b-42d3-a456-426614174000");
    try seedPruneTestRun(allocator, io, namespace, prepared.review_repository_id, first_failure_id, target, "2026-08-20T02:00:00Z", .completed);
    try seedPruneTestRun(allocator, io, namespace, prepared.review_repository_id, failed_id, target, "2026-08-20T01:00:00Z", .completed);
    try seedPruneTestRun(allocator, io, namespace, prepared.review_repository_id, unprocessed_id, target, "2026-08-20T00:00:00Z", .completed);
    var failure_scan = try service.scanMaintenanceFromPath(allocator, io, &environment, repository_path);
    defer failure_scan.deinit(allocator);
    const first_bytes = (try pruneTestRow(&failure_scan.catalog, first_failure_id)).logical_bytes;
    const failure_selected_bytes = first_bytes +
        (try pruneTestRow(&failure_scan.catalog, failed_id)).logical_bytes +
        (try pruneTestRow(&failure_scan.catalog, unprocessed_id)).logical_bytes;
    var delete_context: PruneTestDelete = .{ .namespace = namespace };
    var failure_clock: PruneTestClock = .{ .now = dry_clock.now };
    var failure_stderr = try tmp.dir.createFile(io, "failure-stderr", .{});
    const stopped = try executePruneWithDelete(
        allocator,
        io,
        &environment,
        repository_path,
        apply_policy,
        failure_stderr,
        .{ .context = &failure_clock, .sample = PruneTestClock.sample },
        .{ .context = &delete_context, .call = PruneTestDelete.call },
    );
    failure_stderr.close(io);
    try expectPruneTestTerminal(stopped, .stopped, 3, failure_selected_bytes, 2, 1, first_bytes, 1);
    try std.testing.expectEqualStrings("run_invalid", stopped.code.?);
    try std.testing.expectEqual(@as(usize, 2), delete_context.calls);
    try std.testing.expectEqual(@as(usize, 1), failure_clock.calls);
    try std.testing.expectEqual(@as(?usize, 1), stopped.failed);
    try std.testing.expectEqual(@as(i64, 0), stopped.cleanup_pending.?.integer);
    var terminal_storage: [1024]u8 = undefined;
    var terminal_writer: std.Io.Writer = .fixed(&terminal_storage);
    try writeTerminal(&terminal_writer, stopped);
    var terminal_json = try std.json.parseFromSlice(std.json.Value, allocator, terminal_writer.buffered(), .{});
    defer terminal_json.deinit();
    try std.testing.expectEqualStrings("stopped", terminal_json.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("run_invalid", terminal_json.value.object.get("code").?.string);
    try std.testing.expectEqual(@as(i64, 1), terminal_json.value.object.get("deleted").?.integer);
    try std.testing.expectEqual(@as(i64, 1), terminal_json.value.object.get("failed").?.integer);
    try std.testing.expectEqual(@as(i64, 1), terminal_json.value.object.get("unprocessed").?.integer);
    const failure_output = try tmp.dir.readFileAlloc(io, "failure-stderr", allocator, .limited(64 * 1024));
    defer allocator.free(failure_output);
    try expectPruneCandidates(failure_output, &.{ first_failure_id, failed_id, unprocessed_id });
    try std.testing.expectError(error.FileNotFound, namespace.openDir(io, &first_failure_id.canonical(), .{}));
    var failed_run = try namespace.openDir(io, &failed_id.canonical(), .{});
    failed_run.close(io);
    var unprocessed_run = try namespace.openDir(io, &unprocessed_id.canonical(), .{});
    unprocessed_run.close(io);

    const registry_after = try store.readFileAlloc(io, "registry.json", allocator, .limited(64 * 1024));
    defer allocator.free(registry_after);
    const head_after = try repo.readFileAlloc(io, ".git/HEAD", allocator, .limited(1024));
    defer allocator.free(head_after);
    try std.testing.expectEqualStrings(registry_before, registry_after);
    try std.testing.expectEqualStrings(head_before, head_after);
}

const PruneTestRunMode = enum { unfinished, completed, malformed_draft, unsafe_draft, oversized_draft };

const PruneTestClock = struct {
    now: i64,
    calls: usize = 0,

    fn sample(raw: ?*anyopaque, _: std.Io) ?i64 {
        const self: *PruneTestClock = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        return self.now;
    }
};

const PruneTestDelete = struct {
    namespace: std.Io.Dir,
    calls: usize = 0,

    fn call(raw: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, environment: ?*std.process.Environ.Map, repository_path: []const u8, request: service.DeleteRequest) !service.DeleteResult {
        const self: *PruneTestDelete = @ptrCast(@alignCast(raw.?));
        if (self.calls == 1) {
            var run_directory = try self.namespace.openDir(io, &request.review_id.canonical(), .{});
            defer run_directory.close(io);
            try writePruneTestFile(io, run_directory, "manifest.json", "{}\n");
        }
        self.calls += 1;
        return service.deleteFromPath(allocator, io, environment, repository_path, request);
    }
};

fn seedPruneTestRun(allocator: std.mem.Allocator, io: std.Io, namespace: std.Io.Dir, repository_id: review.ReviewRepositoryId, review_id: review.ReviewId, target: review.CommittedReviewTarget, created_at: []const u8, mode: PruneTestRunMode) !void {
    const name = review_id.canonical();
    try namespace.createDir(io, &name, .fromMode(0o700));
    var directory = try namespace.openDir(io, &name, .{});
    defer directory.close(io);
    const producer: review.Producer = .{ .name = "codex", .model = "gpt-test" };
    const finding_set: review.FindingSet = .{
        .schema_version = 1,
        .review_id = review_id,
        .created_at = created_at,
        .timing = .{ .duration_ms = 1 },
        .target = target,
        .producer = producer,
        .findings = &.{},
    };
    const findings_bytes = try finding_set.writeCanonical(allocator);
    defer allocator.free(findings_bytes);
    const manifest: review.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = review_id,
        .review_repository_id = repository_id,
        .target = target,
        .created_at = created_at,
        .display = null,
        .finding_count = 0,
        .producer = producer,
        .findings_digest = review.Sha256Digest.hash(findings_bytes),
    };
    const manifest_bytes = try manifest.writeCanonical(allocator);
    defer allocator.free(manifest_bytes);
    try writePruneTestFile(io, directory, "manifest.json", manifest_bytes);
    try writePruneTestFile(io, directory, "findings.json", findings_bytes);
    if (mode == .unfinished) return;
    const result: review.RevisionReviewResult = .{
        .schema_version = 1,
        .review_id = review_id,
        .target = target,
        .findings_digest = manifest.findings_digest,
        .result = .approved,
        .completed_at = "2026-08-20T10:00:00Z",
        .summary = null,
        .finding_dispositions = &.{},
        .anchored_notes = &.{},
    };
    const result_bytes = try result.writeCanonical(allocator);
    defer allocator.free(result_bytes);
    try writePruneTestFile(io, directory, "result.json", result_bytes);
    switch (mode) {
        .unfinished, .completed => {},
        .malformed_draft => try writePruneTestFile(io, directory, "review_state.json", ""),
        .unsafe_draft => try directory.symLink(io, "manifest.json", "review_state.json", .{}),
        .oversized_draft => {
            var file = try directory.createFile(io, "review_state.json", .{ .permissions = .fromMode(0o600) });
            defer file.close(io);
            try file.setLength(io, review.limits.max_artifact_bytes + 1);
        },
    }
}

fn writePruneTestFile(io: std.Io, directory: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    try directory.writeFile(io, .{ .sub_path = name, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
}

fn runPruneTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, io, .{ .argv = argv, .cwd = .{ .dir = cwd }, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(64 * 1024) });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.GitCommandFailed;
}

fn pruneTestRow(catalog: *const service.MaintenanceCatalog, id: review.ReviewId) !*const service.MaintenanceRow {
    for (catalog.rows) |*row| if (row.review_id.eql(id)) return row;
    return error.MissingFixtureRun;
}

fn expectPruneCandidates(output: []const u8, ids: []const review.ReviewId) !void {
    var previous: usize = 0;
    for (ids, 0..) |id, index| {
        const prefix = try std.fmt.allocPrint(std.testing.allocator, "Candidate {s} ", .{id.canonical()});
        defer std.testing.allocator.free(prefix);
        const position = std.mem.indexOf(u8, output, prefix) orelse return error.MissingCandidate;
        if (index != 0) try std.testing.expect(previous < position);
        previous = position;
    }
}

fn expectPruneTestTerminal(terminal: Terminal, status: @FieldType(Terminal, "status"), selected: usize, selected_bytes: u64, skipped: usize, deleted: usize, deleted_bytes: u64, unprocessed: usize) !void {
    try std.testing.expectEqual(status, terminal.status);
    try std.testing.expectEqual(selected, terminal.selected.?);
    try std.testing.expectEqual(selected_bytes, terminal.selected_logical_bytes.?);
    try std.testing.expectEqual(skipped, terminal.skipped.?);
    if (terminal.status != .prune_preview) {
        try std.testing.expectEqual(deleted, terminal.deleted.?);
        try std.testing.expectEqual(deleted_bytes, terminal.deleted_logical_bytes.?);
        try std.testing.expectEqual(unprocessed, terminal.unprocessed.?);
    }
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
        try std.testing.expect(pending.cleanup_pending.? == .bool);
        try std.testing.expect(pending.cleanup_pending.?.bool);
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
