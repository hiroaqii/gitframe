//! Exact, bounded first-parent commit catalog reads.
//!
//! Traversal output supplies display metadata and ordering only. Parent
//! authority always comes from the exact raw commit objects and is admitted
//! in one no-lazy-fetch availability transaction before any record is
//! published.

const std = @import("std");
const committed_review = @import("committed_review.zig");
const git_command = @import("command.zig");

pub const ObjectFormat = committed_review.ObjectFormat;
pub const ObjectId = committed_review.ObjectId;

pub const page_size: usize = 200;
pub const traversal_limit: usize = page_size + 1;
pub const catalog_limit: usize = 2000;

const stderr_limit: usize = 16 * 1024;
const metadata_limit: usize = 1024 * 1024;
const raw_commit_limit: usize = 8 * 1024 * 1024;
const availability_limit: usize = 64 * 1024;
const display_field_limit: usize = 16 * 1024;

const strict_prefix = [_][]const u8{
    "git",
    "--no-replace-objects",
    "--no-lazy-fetch",
    "--no-optional-locks",
};

pub const FirstParent = union(enum) {
    true_root,
    available: ObjectId,
    missing: ObjectId,
};

pub const Record = struct {
    oid: ObjectId,
    parent_count: u16,
    first_parent: FirstParent,
    author: []u8,
    committer_unix: i64,
    decorations: []u8,
    subject: []u8,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.author);
        allocator.free(self.decorations);
        allocator.free(self.subject);
        self.* = undefined;
    }
};

pub const HeadDisplay = union(enum) {
    branch: []u8,
    detached,
    unborn: []u8,

    pub fn deinit(self: *HeadDisplay, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .branch, .unborn => |text| allocator.free(text),
            .detached => {},
        }
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    object_format: ObjectFormat,
    head: ?ObjectId,
    display: HeadDisplay,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        self.display.deinit(allocator);
        self.* = undefined;
    }
};

pub const Page = struct {
    /// Present only for the initial request. Continuation requests borrow the
    /// already accepted page snapshot and cannot replace it.
    snapshot: ?Snapshot = null,
    records: []Record = &.{},
    continuation: ?ObjectId = null,

    pub fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        if (self.snapshot) |*snapshot| snapshot.deinit(allocator);
        for (self.records) |*record| record.deinit(allocator);
        allocator.free(self.records);
        self.* = .{};
    }

    pub fn takeSnapshot(self: *Page) ?Snapshot {
        const snapshot = self.snapshot;
        self.snapshot = null;
        return snapshot;
    }

    pub fn takeRecords(self: *Page) []Record {
        const records = self.records;
        self.records = &.{};
        return records;
    }
};

pub const Failure = enum {
    invalid_repository,
    unsupported_object_format,
    object_format_drift,
    head_unavailable,
    malformed_catalog,
    output_too_large,
    git_command_failed,
};

pub const LoadResult = union(enum) {
    loaded: Page,
    failure: Failure,

    pub fn deinit(self: *LoadResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .loaded => |*page| page.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .git_command_failed };
    }
};

pub fn loadInitial(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) std.mem.Allocator.Error!LoadResult {
    const format = switch (try readObjectFormat(allocator, io, context)) {
        .format => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };

    var snapshot = switch (try readHeadSnapshot(allocator, io, context, format)) {
        .snapshot => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    errdefer snapshot.deinit(allocator);
    const head = snapshot.head orelse return .{ .loaded = .{ .snapshot = snapshot } };

    var page = switch (try loadPage(allocator, io, context, format, head)) {
        .loaded => |value| value,
        .failure => |failure| {
            snapshot.deinit(allocator);
            return .{ .failure = failure };
        },
    };
    page.snapshot = snapshot;
    return .{ .loaded = page };
}

pub fn loadContinuation(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    expected_format: ObjectFormat,
    cursor: ObjectId,
) std.mem.Allocator.Error!LoadResult {
    if (!cursor.validFor(expected_format)) return .{ .failure = .malformed_catalog };
    const actual_format = switch (try readObjectFormat(allocator, io, context)) {
        .format => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    if (actual_format != expected_format) return .{ .failure = .object_format_drift };
    return loadPage(allocator, io, context, expected_format, cursor);
}

const FormatResult = union(enum) {
    format: ObjectFormat,
    failure: Failure,
};

fn readObjectFormat(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) std.mem.Allocator.Error!FormatResult {
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1],       strict_prefix[2], strict_prefix[3],
        "rev-parse",      "--show-object-format",
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(16),
        .stderr_limit = .limited(stderr_limit),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded => return .{ .failure = .output_too_large },
        .failed => return .{ .failure = .git_command_failed },
    };
    if (!exited(completed.term, 0)) return .{ .failure = .invalid_repository };
    const line = exactLine(completed.stdout) orelse return .{ .failure = .git_command_failed };
    if (std.mem.eql(u8, line, "sha1")) return .{ .format = .sha1 };
    if (std.mem.eql(u8, line, "sha256")) return .{ .format = .sha256 };
    return .{ .failure = .unsupported_object_format };
}

const SnapshotResult = union(enum) {
    snapshot: Snapshot,
    failure: Failure,
};

fn readHeadSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
) std.mem.Allocator.Error!SnapshotResult {
    const symbolic_argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "symbolic-ref",   "--quiet",        "HEAD",
    };
    var symbolic_result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &symbolic_argv,
        .stdout_limit = .limited(display_field_limit),
        .stderr_limit = .limited(stderr_limit),
    });
    defer symbolic_result.deinit(allocator);
    const symbolic = switch (symbolic_result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded => return .{ .failure = .output_too_large },
        .failed => return .{ .failure = .git_command_failed },
    };
    var symbolic_ref: ?[]const u8 = null;
    var branch: ?[]u8 = null;
    errdefer if (branch) |owned| allocator.free(owned);
    if (exited(symbolic.term, 0)) {
        const line = exactLine(symbolic.stdout) orelse return .{ .failure = .malformed_catalog };
        if (line.len == 0 or !std.unicode.utf8ValidateSlice(line)) return .{ .failure = .malformed_catalog };
        symbolic_ref = line;
        const heads_prefix = "refs/heads/";
        const display = if (std.mem.startsWith(u8, line, heads_prefix)) line[heads_prefix.len..] else line;
        if (display.len == 0) return .{ .failure = .malformed_catalog };
        branch = try allocator.dupe(u8, display);
    } else if (!exited(symbolic.term, 1)) {
        return .{ .failure = .git_command_failed };
    }

    const head_argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "rev-parse",      "--verify",       "HEAD^{commit}",
    };
    var head_result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &head_argv,
        .stdout_limit = .limited(format.oidHexLength() + 1),
        .stderr_limit = .limited(stderr_limit),
    });
    defer head_result.deinit(allocator);
    const head_completed = switch (head_result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded => return .{ .failure = .output_too_large },
        .failed => return .{ .failure = .git_command_failed },
    };
    if (!exited(head_completed.term, 0)) {
        switch (head_completed.term) {
            .exited => {},
            else => return .{ .failure = .git_command_failed },
        }
        const full_ref = symbolic_ref orelse return .{ .failure = .head_unavailable };
        const verify_ref_argv = [_][]const u8{
            strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
            "show-ref",       "--verify",       "--quiet",        full_ref,
        };
        var verify_ref_result = try git_command.runCapturedBounded(allocator, io, context, .{
            .argv = &verify_ref_argv,
            .stdout_limit = .limited(0),
            .stderr_limit = .limited(stderr_limit),
        });
        defer verify_ref_result.deinit(allocator);
        const verified_ref = switch (verify_ref_result) {
            .completed => |value| value,
            .stdout_limit_exceeded, .stderr_limit_exceeded => return .{ .failure = .output_too_large },
            .failed => return .{ .failure = .git_command_failed },
        };
        if (exited(verified_ref.term, 0)) return .{ .failure = .head_unavailable };
        if (!exited(verified_ref.term, 1)) return .{ .failure = .git_command_failed };
        const unborn = branch orelse return .{ .failure = .head_unavailable };
        branch = null;
        return .{ .snapshot = .{
            .object_format = format,
            .head = null,
            .display = .{ .unborn = unborn },
        } };
    }
    const head_line = exactLine(head_completed.stdout) orelse return .{ .failure = .malformed_catalog };
    const head = ObjectId.parse(format, head_line) catch return .{ .failure = .malformed_catalog };
    const display: HeadDisplay = if (branch) |owned| blk: {
        branch = null;
        break :blk .{ .branch = owned };
    } else .detached;
    return .{ .snapshot = .{ .object_format = format, .head = head, .display = display } };
}

const Metadata = struct {
    oid: ObjectId,
    author: []const u8,
    committer_unix: i64,
    decorations: []const u8,
    subject: []const u8,
};

const RawParent = struct {
    count: u16 = 0,
    first: ?ObjectId = null,
};

const ParentAvailability = enum { available, missing };

fn loadPage(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    start: ObjectId,
) std.mem.Allocator.Error!LoadResult {
    const log_argv = [_][]const u8{
        strict_prefix[0],   strict_prefix[1],  strict_prefix[2],                        strict_prefix[3],
        "log",              "-z",              "--first-parent",                        "--no-color",
        "--decorate=short", "--max-count=201", "--format=%H%x00%an%x00%at%x00%D%x00%s", start.slice(),
    };
    var log_result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &log_argv,
        .stdout_limit = .limited(metadata_limit),
        .stderr_limit = .limited(stderr_limit),
    });
    defer log_result.deinit(allocator);
    const log = switch (log_result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded => return .{ .failure = .output_too_large },
        .failed => return .{ .failure = .git_command_failed },
    };
    if (!exited(log.term, 0)) return .{ .failure = .git_command_failed };

    var metadata_storage: [traversal_limit]Metadata = undefined;
    const metadata = parseMetadata(format, log.stdout, &metadata_storage) orelse
        return .{ .failure = .malformed_catalog };
    if (metadata.len == 0 or !metadata[0].oid.eql(&start)) return .{ .failure = .malformed_catalog };

    var object_stdin: std.ArrayList(u8) = .empty;
    defer object_stdin.deinit(allocator);
    for (metadata) |entry| {
        try object_stdin.appendSlice(allocator, entry.oid.slice());
        try object_stdin.append(allocator, '\n');
    }
    const raw_argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "cat-file",       "--batch",
    };
    var raw_result = try git_command.runWithStdinBounded(allocator, io, context, .{
        .argv = &raw_argv,
        .stdin = object_stdin.items,
        .stdout_limit = .limited(raw_commit_limit),
        .stderr_limit = .limited(stderr_limit),
    });
    defer raw_result.deinit(allocator);
    const raw = switch (raw_result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded => return .{ .failure = .output_too_large },
        .failed => return .{ .failure = .git_command_failed },
    };
    if (!exited(raw.term, 0)) return .{ .failure = .git_command_failed };
    var parent_storage: [traversal_limit]RawParent = undefined;
    const parents = parseRawCommits(format, metadata, raw.stdout, &parent_storage) orelse
        return .{ .failure = .malformed_catalog };

    var parent_stdin: std.ArrayList(u8) = .empty;
    defer parent_stdin.deinit(allocator);
    var parent_count: usize = 0;
    for (parents) |parent| if (parent.first) |first| {
        try parent_stdin.appendSlice(allocator, first.slice());
        try parent_stdin.append(allocator, '\n');
        parent_count += 1;
    };
    var availability_storage: [traversal_limit]ParentAvailability = undefined;
    const availability = availability_storage[0..parent_count];
    if (parent_count > 0) {
        const check_argv = [_][]const u8{
            strict_prefix[0], strict_prefix[1],                            strict_prefix[2], strict_prefix[3],
            "cat-file",       "--batch-check=%(objectname) %(objecttype)",
        };
        var check_result = try git_command.runWithStdinBounded(allocator, io, context, .{
            .argv = &check_argv,
            .stdin = parent_stdin.items,
            .stdout_limit = .limited(availability_limit),
            .stderr_limit = .limited(stderr_limit),
        });
        defer check_result.deinit(allocator);
        const checked = switch (check_result) {
            .completed => |value| value,
            .stdout_limit_exceeded, .stderr_limit_exceeded => return .{ .failure = .output_too_large },
            .failed => return .{ .failure = .git_command_failed },
        };
        if (!exited(checked.term, 0) or
            !parseAvailability(format, parents, checked.stdout, availability))
        {
            return .{ .failure = .malformed_catalog };
        }
    }

    var classified_storage: [traversal_limit]FirstParent = undefined;
    const classified = classified_storage[0..parents.len];
    var available_index: usize = 0;
    for (parents, classified) |parent, *classification| {
        if (parent.first) |first| {
            classification.* = switch (availability[available_index]) {
                .available => .{ .available = first },
                .missing => .{ .missing = first },
            };
            available_index += 1;
        } else {
            classification.* = .true_root;
        }
    }
    if (!validTraversal(metadata, classified)) return .{ .failure = .malformed_catalog };
    const continuation: ?ObjectId = if (metadata.len == traversal_limit)
        switch (classified[page_size - 1]) {
            .available => |oid| oid,
            .true_root, .missing => unreachable,
        }
    else
        null;

    const kept_len = @min(metadata.len, page_size);
    const records = try allocator.alloc(Record, kept_len);
    var initialized: usize = 0;
    errdefer {
        for (records[0..initialized]) |*record| record.deinit(allocator);
        allocator.free(records);
    }
    for (metadata[0..kept_len], parents[0..kept_len], classified[0..kept_len], records) |entry, parent, first_parent, *record| {
        record.* = .{
            .oid = entry.oid,
            .parent_count = parent.count,
            .first_parent = first_parent,
            .author = try allocator.dupe(u8, entry.author),
            .committer_unix = entry.committer_unix,
            .decorations = &.{},
            .subject = &.{},
        };
        errdefer allocator.free(record.author);
        record.decorations = try allocator.dupe(u8, entry.decorations);
        errdefer allocator.free(record.decorations);
        record.subject = try allocator.dupe(u8, entry.subject);
        initialized += 1;
    }
    return .{ .loaded = .{
        .records = records,
        .continuation = continuation,
    } };
}

fn parseMetadata(format: ObjectFormat, bytes: []const u8, storage: *[traversal_limit]Metadata) ?[]Metadata {
    var offset: usize = 0;
    var len: usize = 0;
    while (offset < bytes.len) {
        if (len == storage.len) return null;
        const oid_text = nextNulField(bytes, &offset) orelse return null;
        const author = nextNulField(bytes, &offset) orelse return null;
        const timestamp = nextNulField(bytes, &offset) orelse return null;
        const decorations = nextNulField(bytes, &offset) orelse return null;
        const subject = nextNulField(bytes, &offset) orelse return null;
        if (author.len > display_field_limit or decorations.len > display_field_limit or
            subject.len > display_field_limit or !std.unicode.utf8ValidateSlice(author) or
            !std.unicode.utf8ValidateSlice(decorations) or !std.unicode.utf8ValidateSlice(subject)) return null;
        const unix = std.fmt.parseInt(i64, timestamp, 10) catch return null;
        storage[len] = .{
            .oid = ObjectId.parse(format, oid_text) catch return null,
            .author = author,
            .committer_unix = unix,
            .decorations = decorations,
            .subject = subject,
        };
        len += 1;
    }
    return storage[0..len];
}

fn parseRawCommits(
    format: ObjectFormat,
    metadata: []const Metadata,
    bytes: []const u8,
    storage: *[traversal_limit]RawParent,
) ?[]RawParent {
    var offset: usize = 0;
    for (metadata, 0..) |entry, index| {
        const header_end = std.mem.indexOfScalarPos(u8, bytes, offset, '\n') orelse return null;
        const batch_header = bytes[offset..header_end];
        offset = header_end + 1;
        var fields = std.mem.splitScalar(u8, batch_header, ' ');
        const oid_text = fields.next() orelse return null;
        const kind = fields.next() orelse return null;
        const size_text = fields.next() orelse return null;
        if (fields.next() != null or !std.mem.eql(u8, oid_text, entry.oid.slice()) or
            !std.mem.eql(u8, kind, "commit")) return null;
        const size = std.fmt.parseInt(usize, size_text, 10) catch return null;
        if (size > bytes.len - offset) return null;
        const object = bytes[offset .. offset + size];
        offset += size;
        if (offset >= bytes.len or bytes[offset] != '\n') return null;
        offset += 1;
        storage[index] = parseRawParent(format, object) orelse return null;
    }
    if (offset != bytes.len) return null;
    return storage[0..metadata.len];
}

fn parseRawParent(format: ObjectFormat, object: []const u8) ?RawParent {
    const header_end = std.mem.indexOf(u8, object, "\n\n") orelse return null;
    var result: RawParent = .{};
    var lines = std.mem.splitScalar(u8, object[0..header_end], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "parent ")) continue;
        const oid = ObjectId.parse(format, line["parent ".len..]) catch return null;
        if (result.count == std.math.maxInt(u16)) return null;
        result.count += 1;
        if (result.first == null) result.first = oid;
    }
    return result;
}

fn parseAvailability(
    format: ObjectFormat,
    parents: []const RawParent,
    bytes: []const u8,
    output: []ParentAvailability,
) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var index: usize = 0;
    for (parents) |parent| if (parent.first) |first| {
        const line = lines.next() orelse return false;
        const oid_len = format.oidHexLength();
        if (line.len <= oid_len or !std.mem.eql(u8, line[0..oid_len], first.slice()) or line[oid_len] != ' ') return false;
        const kind = line[oid_len + 1 ..];
        output[index] = if (std.mem.eql(u8, kind, "commit"))
            .available
        else if (std.mem.eql(u8, kind, "missing"))
            .missing
        else
            return false;
        index += 1;
    };
    const terminal = lines.next() orelse return false;
    return terminal.len == 0 and lines.next() == null and index == output.len;
}

fn validTraversal(metadata: []const Metadata, parents: []const FirstParent) bool {
    if (metadata.len == 0 or metadata.len != parents.len or metadata.len > traversal_limit) return false;
    for (metadata[1..], parents[0 .. metadata.len - 1]) |next, parent| switch (parent) {
        .available => |oid| if (!oid.eql(&next.oid)) return false,
        .true_root, .missing => return false,
    };
    if (metadata.len == traversal_limit) return switch (parents[page_size - 1]) {
        .available => |oid| oid.eql(&metadata[page_size].oid),
        .true_root, .missing => false,
    };
    return switch (parents[parents.len - 1]) {
        .true_root, .missing => true,
        .available => false,
    };
}

fn nextNulField(bytes: []const u8, offset: *usize) ?[]const u8 {
    if (offset.* >= bytes.len) return null;
    const end = std.mem.indexOfScalarPos(u8, bytes, offset.*, 0) orelse return null;
    const field = bytes[offset.*..end];
    offset.* = end + 1;
    return field;
}

fn exactLine(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0) return null;
    const line = if (bytes[bytes.len - 1] == '\n') bytes[0 .. bytes.len - 1] else return null;
    if (std.mem.indexOfScalar(u8, line, '\n') != null or std.mem.indexOfScalar(u8, line, 0) != null) return null;
    return line;
}

fn exited(term: std.process.Child.Term, expected: u8) bool {
    return switch (term) {
        .exited => |code| code == expected,
        else => false,
    };
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn runTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer freeRunResult(std.testing.allocator, result);
    if (!exited(result.term, 0)) return error.GitCommandFailed;
}

fn importLinearHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    commit_count: usize,
) !void {
    var stream: std.Io.Writer.Allocating = .init(allocator);
    defer stream.deinit();
    for (1..commit_count + 1) |number| {
        var subject_buffer: [32]u8 = undefined;
        const subject = try std.fmt.bufPrint(&subject_buffer, "commit {d}", .{number});
        try stream.writer.print(
            "commit refs/heads/main\nmark :{d}\ncommitter Test <test@example.invalid> {d} +0000\ndata {d}\n{s}\n",
            .{ number, number, subject.len, subject },
        );
        if (number > 1) try stream.writer.print("from :{d}\n", .{number - 1});
        try stream.writer.writeAll("deleteall\n\n");
    }

    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    const argv = [_][]const u8{ "git", "fast-import", "--quiet" };
    const result = try git_command.runWithStdin(allocator, io, .{
        .cwd = cwd,
        .environment = &environment,
    }, .{
        .argv = &argv,
        .stdin = stream.written(),
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer result.deinit(allocator);
    if (!exited(result.term, 0)) return error.GitCommandFailed;
    try runTestGit(io, cwd, &.{ "git", "symbolic-ref", "HEAD", "refs/heads/main" });
    try runTestGit(io, cwd, &.{ "git", "reset", "--hard", "main" });
}

test "History exact catalog pages full topology and preserves shallow raw parent boundary" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "source", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{});
    defer source.close(io);
    try runTestGit(io, source, &.{ "git", "init", "--object-format=sha1", "-q" });
    try importLinearHistory(allocator, io, source, 205);

    const source_path = try tmp.dir.realPathFileAlloc(io, "source", allocator);
    defer allocator.free(source_path);
    const source_url = try std.fmt.allocPrint(allocator, "file://{s}", .{source_path});
    defer allocator.free(source_url);
    try runTestGit(io, tmp.dir, &.{ "git", "clone", "-q", "--depth=2", "--no-single-branch", source_url, "shallow" });
    var shallow = try tmp.dir.openDir(io, "shallow", .{});
    defer shallow.close(io);

    var environment = try git_command.LocalGitEnvironment.initFromParent(allocator, null);
    defer environment.deinit();
    const source_context: git_command.DirectoryContext = .{ .cwd = source, .environment = &environment };
    var initial = try loadInitial(allocator, io, source_context);
    defer initial.deinit(allocator);
    const first_page = switch (initial) {
        .loaded => |*page| page,
        .failure => return error.ExpectedLoadedCatalog,
    };
    try std.testing.expectEqual(@as(usize, page_size), first_page.records.len);
    try std.testing.expect(first_page.continuation != null);
    try std.testing.expectEqualStrings("commit 205", first_page.records[0].subject);
    try std.testing.expectEqualStrings("commit 6", first_page.records[page_size - 1].subject);
    try std.testing.expect(first_page.snapshot.?.display == .branch);
    try std.testing.expectEqualStrings("main", first_page.snapshot.?.display.branch);

    var older = try loadContinuation(
        allocator,
        io,
        source_context,
        first_page.snapshot.?.object_format,
        first_page.continuation.?,
    );
    defer older.deinit(allocator);
    const older_page = switch (older) {
        .loaded => |*page| page,
        .failure => return error.ExpectedLoadedCatalog,
    };
    try std.testing.expectEqual(@as(usize, 5), older_page.records.len);
    try std.testing.expectEqualStrings("commit 5", older_page.records[0].subject);
    try std.testing.expectEqualStrings("commit 1", older_page.records[4].subject);
    try std.testing.expect(older_page.records[4].first_parent == .true_root);
    try std.testing.expect(older_page.continuation == null);

    const shallow_context: git_command.DirectoryContext = .{ .cwd = shallow, .environment = &environment };
    var shallow_result = try loadInitial(allocator, io, shallow_context);
    defer shallow_result.deinit(allocator);
    const shallow_page = switch (shallow_result) {
        .loaded => |*page| page,
        .failure => return error.ExpectedLoadedCatalog,
    };
    try std.testing.expectEqual(@as(usize, 2), shallow_page.records.len);
    try std.testing.expect(shallow_page.records[0].first_parent == .available);
    try std.testing.expect(shallow_page.records[1].first_parent == .missing);
    try std.testing.expect(shallow_page.continuation == null);

    try runTestGit(io, source, &.{ "git", "switch", "--detach", "-q", "HEAD" });
    var detached = try loadInitial(allocator, io, source_context);
    defer detached.deinit(allocator);
    switch (detached) {
        .loaded => |page| try std.testing.expect(page.snapshot.?.display == .detached),
        .failure => return error.ExpectedDetachedCatalog,
    }

    try tmp.dir.createDir(io, "unborn", .default_dir);
    var unborn_dir = try tmp.dir.openDir(io, "unborn", .{});
    defer unborn_dir.close(io);
    try runTestGit(io, unborn_dir, &.{ "git", "init", "-q", "--initial-branch=topic" });
    const unborn_context: git_command.DirectoryContext = .{ .cwd = unborn_dir, .environment = &environment };
    var unborn = try loadInitial(allocator, io, unborn_context);
    defer unborn.deinit(allocator);
    switch (unborn) {
        .loaded => |page| {
            try std.testing.expectEqual(@as(usize, 0), page.records.len);
            try std.testing.expect(page.snapshot.?.head == null);
            try std.testing.expectEqualStrings("topic", page.snapshot.?.display.unborn);
        },
        .failure => return error.ExpectedUnbornCatalog,
    }
}

test "History metadata parser is bounded and preserves exact display fields" {
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const bytes = oid ++ "\x00Alice\x0017\x00HEAD -> main\x00subject\x00";
    var storage: [traversal_limit]Metadata = undefined;
    const parsed = parseMetadata(.sha1, bytes, &storage).?;
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqualStrings(oid, parsed[0].oid.slice());
    try std.testing.expectEqualStrings("Alice", parsed[0].author);
    try std.testing.expectEqual(@as(i64, 17), parsed[0].committer_unix);
    try std.testing.expectEqualStrings("HEAD -> main", parsed[0].decorations);
    try std.testing.expectEqualStrings("subject", parsed[0].subject);
}

test "History raw parent parser distinguishes true root and merge first parent" {
    const first = "0123456789abcdef0123456789abcdef01234567";
    const second = "89abcdef0123456789abcdef0123456789abcdef";
    const root = parseRawParent(.sha1, "tree 1111111111111111111111111111111111111111\nauthor A <a@b> 0 +0000\n\nroot\n").?;
    try std.testing.expectEqual(@as(u16, 0), root.count);
    try std.testing.expect(root.first == null);
    const merge_text = "tree 1111111111111111111111111111111111111111\nparent " ++ first ++ "\nparent " ++ second ++ "\nauthor A <a@b> 0 +0000\n\nmerge\n";
    const merge = parseRawParent(.sha1, merge_text).?;
    try std.testing.expectEqual(@as(u16, 2), merge.count);
    try std.testing.expectEqualStrings(first, merge.first.?.slice());
}

test "History traversal requires raw adjacent parents and typed terminal boundary" {
    const a = try ObjectId.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const b = try ObjectId.parse(.sha1, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const metadata = [_]Metadata{
        .{ .oid = a, .author = "A", .committer_unix = 1, .decorations = "", .subject = "a" },
        .{ .oid = b, .author = "B", .committer_unix = 0, .decorations = "", .subject = "b" },
    };
    try std.testing.expect(validTraversal(&metadata, &.{ .{ .available = b }, .true_root }));
    try std.testing.expect(validTraversal(&metadata, &.{ .{ .available = b }, .{ .missing = a } }));
    try std.testing.expect(!validTraversal(&metadata, &.{ .{ .available = a }, .true_root }));
    try std.testing.expect(!validTraversal(&metadata, &.{ .{ .available = b }, .{ .available = a } }));
}
