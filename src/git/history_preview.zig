//! App-independent owned data contract for History commit and range previews.
//!
//! Bounded Git reads and causal admission live here; async task ownership,
//! rendering, and clipboard formatting remain later responsibilities. Raw
//! identity bytes and exact committed-diff bases stay independent of them.

const std = @import("std");
const commit_diff = @import("commit_diff.zig");
const git_command = @import("command.zig");
const history = @import("history.zig");
const path_key = @import("../path_key.zig");

pub const Timestamp = struct {
    unix_seconds: i64,
    original_offset: [5]u8,
    offset_minutes: i16,

    pub fn init(unix_seconds: i64, original_offset: []const u8) error{InvalidTimezone}!Timestamp {
        if (original_offset.len != 5 or
            (original_offset[0] != '+' and original_offset[0] != '-')) return error.InvalidTimezone;
        for (original_offset[1..]) |byte| {
            if (!std.ascii.isDigit(byte)) return error.InvalidTimezone;
        }
        const hours: i16 = @intCast((original_offset[1] - '0') * 10 + original_offset[2] - '0');
        const minutes: i16 = @intCast((original_offset[3] - '0') * 10 + original_offset[4] - '0');
        if (hours > 23 or minutes > 59) return error.InvalidTimezone;
        const magnitude = hours * 60 + minutes;
        return .{
            .unix_seconds = unix_seconds,
            .original_offset = original_offset[0..5].*,
            .offset_minutes = if (original_offset[0] == '-') -magnitude else magnitude,
        };
    }
};

pub const Identity = struct {
    name: []const u8,
    email: []const u8,

    pub fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.email.len > 0) allocator.free(self.email);
        self.* = undefined;
    }
};

pub const TypedRefs = struct {
    local_branches: []const []const u8,
    tags: []const []const u8,
    remote_branches: []const []const u8,

    pub fn deinit(self: *TypedRefs, allocator: std.mem.Allocator) void {
        freeOwnedStrings(allocator, self.local_branches);
        freeOwnedStrings(allocator, self.tags);
        freeOwnedStrings(allocator, self.remote_branches);
        self.* = undefined;
    }
};

pub const SingleSummary = struct {
    selected_oid: commit_diff.ObjectId,
    parent_count: u32,
    basis: commit_diff.Basis,
};

pub const RangeSummary = struct {
    count: usize,
    oldest_oid: commit_diff.ObjectId,
    newest_oid: commit_diff.ObjectId,
    basis: commit_diff.Basis,
};

pub const SelectionSummary = union(enum) {
    single: SingleSummary,
    range: RangeSummary,

    pub fn basis(self: SelectionSummary) commit_diff.Basis {
        return switch (self) {
            .single => |single| single.basis,
            .range => |range| range.basis,
        };
    }
};

pub const SingleDetail = struct {
    summary: SingleSummary,
    author: Identity,
    authored: Timestamp,
    committer: Identity,
    committed: Timestamp,
    refs: TypedRefs,
    message: []const u8,

    pub fn deinit(self: *SingleDetail, allocator: std.mem.Allocator) void {
        self.author.deinit(allocator);
        self.committer.deinit(allocator);
        self.refs.deinit(allocator);
        if (self.message.len > 0) allocator.free(self.message);
        self.* = undefined;
    }
};

pub const Detail = union(enum) {
    single: SingleDetail,
    range: RangeSummary,

    pub fn deinit(self: *Detail, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .single => |*single| single.deinit(allocator),
            .range => {},
        }
        self.* = undefined;
    }
};

pub const DetailTooLargeStage = enum {
    commit_object,
    metadata,
    message,
    identity,
    refs,
};

pub const UnavailableReason = enum {
    repository_format_drift,
    before_missing,
    before_wrong_kind,
    after_missing,
    after_wrong_kind,
};

pub const FailureReason = enum {
    git_command,
    malformed_output,
    allocation,
    task_start,
};

pub const DetailResult = union(enum) {
    ready: Detail,
    too_large: DetailTooLargeStage,
    unavailable: UnavailableReason,
    failed: FailureReason,

    pub fn deinit(self: *DetailResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |*detail| detail.deinit(allocator),
            .too_large, .unavailable, .failed => {},
        }
        self.* = undefined;
    }
};

pub const FileStatus = enum {
    modified,
    added,
    deleted,
    renamed,
    type_changed,

    pub fn badge(self: FileStatus) []const u8 {
        return switch (self) {
            .modified => "M",
            .added => "A",
            .deleted => "D",
            .renamed => "R",
            .type_changed => "T",
        };
    }
};

/// Single authority for a file change's status, path shape, and rename score.
/// Non-rename variants can own only one path; only the rename variant can own
/// a similarity score and old/new path pair.
pub const FileChangeKind = union(FileStatus) {
    modified: []const u8,
    added: []const u8,
    deleted: []const u8,
    renamed: Rename,
    type_changed: []const u8,

    pub const Rename = struct {
        similarity: u8,
        old: []const u8,
        new: []const u8,
    };

    pub fn status(self: FileChangeKind) FileStatus {
        return std.meta.activeTag(self);
    }

    pub fn badge(self: FileChangeKind) []const u8 {
        return self.status().badge();
    }

    pub fn canonicalPath(self: FileChangeKind) []const u8 {
        return switch (self) {
            .modified, .added, .deleted, .type_changed => |path| path,
            .renamed => |rename| rename.new,
        };
    }

    pub fn renameSimilarity(self: FileChangeKind) ?u8 {
        return switch (self) {
            .renamed => |rename| rename.similarity,
            else => null,
        };
    }

    pub fn deinit(self: *FileChangeKind, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .modified, .added, .deleted, .type_changed => |path| if (path.len > 0) allocator.free(path),
            .renamed => |rename| {
                if (rename.old.len > 0) allocator.free(rename.old);
                if (rename.new.len > 0) allocator.free(rename.new);
            },
        }
        self.* = undefined;
    }
};

pub const TextStats = struct {
    added: u64,
    removed: u64,
};

pub const StatsKind = union(enum) {
    text: TextStats,
    binary,
    mode_only,
    submodule,
};

pub const FileChange = struct {
    kind: FileChangeKind,
    old_mode: u32,
    new_mode: u32,
    old_oid: commit_diff.ObjectId,
    new_oid: commit_diff.ObjectId,
    stats: StatsKind,

    pub fn status(self: FileChange) FileStatus {
        return self.kind.status();
    }

    pub fn statusBadge(self: FileChange) []const u8 {
        return self.kind.badge();
    }

    pub fn canonicalPath(self: FileChange) []const u8 {
        return self.kind.canonicalPath();
    }

    pub fn renameSimilarity(self: FileChange) ?u8 {
        return self.kind.renameSimilarity();
    }

    pub fn deinit(self: *FileChange, allocator: std.mem.Allocator) void {
        self.kind.deinit(allocator);
        self.* = undefined;
    }
};

pub fn fileChangeLessThan(_: void, left: FileChange, right: FileChange) bool {
    return path_key.displayPathLessThan({}, left.canonicalPath(), right.canonicalPath());
}

pub const FilesTooLargeStage = enum {
    raw,
    numstat,
    file_list,
};

pub const FilesResult = union(enum) {
    ready: []FileChange,
    too_large: FilesTooLargeStage,
    unavailable: UnavailableReason,
    failed: FailureReason,

    pub fn deinit(self: *FilesResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |changes| {
                for (changes) |*change| change.deinit(allocator);
                if (changes.len > 0) allocator.free(changes);
            },
            .too_large, .unavailable, .failed => {},
        }
        self.* = undefined;
    }
};

/// Generation-free owned value. Async request identity belongs to the task or
/// accepted wrapper, never to this cacheable payload.
pub const PreviewPayload = struct {
    detail: DetailResult,
    files: FilesResult,

    pub fn deinit(self: *PreviewPayload, allocator: std.mem.Allocator) void {
        self.detail.deinit(allocator);
        self.files.deinit(allocator);
        self.* = undefined;
    }
};

pub const SelectionTooLargeStage = enum {
    selection_graph,
    root_probe,
};

pub const SelectionAdmissionTerminal = union(enum) {
    malformed,
    unavailable,
    too_large: SelectionTooLargeStage,
    failed: FailureReason,
};

pub const VerifiedPreview = struct {
    summary: SelectionSummary,
    payload: PreviewPayload,

    pub fn deinit(self: *VerifiedPreview, allocator: std.mem.Allocator) void {
        self.payload.deinit(allocator);
        self.* = undefined;
    }
};

pub const PreviewReadResult = union(enum) {
    verified: VerifiedPreview,
    rejected: SelectionAdmissionTerminal,

    pub fn deinit(self: *PreviewReadResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .verified => |*verified| verified.deinit(allocator),
            .rejected => {},
        }
        self.* = undefined;
    }
};

const stderr_limit: usize = 16 * 1024;
const selection_graph_limit: usize = 4 * 1024 * 1024;
const commit_object_limit: usize = 2 * 1024 * 1024;
const commit_response_slack: usize = 128;
const metadata_limit: usize = 256 * 1024;
const message_limit: usize = 1024 * 1024;
const identity_field_limit: usize = 16 * 1024;
const refs_output_limit: usize = 1024 * 1024;
const ref_record_limit: usize = 4096;
const ref_name_limit: usize = 16 * 1024;
const raw_output_limit: usize = 4 * 1024 * 1024;
const numstat_output_limit: usize = 4 * 1024 * 1024;
const file_count_limit: usize = 20_000;
const file_payload_limit: usize = 8 * 1024 * 1024;

const CommitView = struct {
    author_name: []const u8,
    author_email: []const u8,
    authored: Timestamp,
    committer_name: []const u8,
    committer_email: []const u8,
    committed: Timestamp,
    message: []const u8,
};

const CommitParseError = error{
    Malformed,
    MetadataTooLarge,
    MessageTooLarge,
    IdentityTooLarge,
};

const RefsReadResult = union(enum) {
    ready: TypedRefs,
    too_large,
    failed: FailureReason,
};

const ProjectionCapture = union(enum) {
    bytes: []u8,
    too_large,
    failed,
};

const PreviewCommand = enum {
    selection_graph,
    root_probe,
    commit_metadata,
    refs,
    raw,
    numstat,
};

const PreviewCommandCounts = struct {
    selection_graph: usize = 0,
    root_probe: usize = 0,
    commit_metadata: usize = 0,
    refs: usize = 0,
    raw: usize = 0,
    numstat: usize = 0,

    fn record(self: *PreviewCommandCounts, command: PreviewCommand) void {
        switch (command) {
            .selection_graph => self.selection_graph += 1,
            .root_probe => self.root_probe += 1,
            .commit_metadata => self.commit_metadata += 1,
            .refs => self.refs += 1,
            .raw => self.raw += 1,
            .numstat => self.numstat += 1,
        }
    }
};

const RawStatus = union(enum) {
    modified,
    added,
    deleted,
    renamed: u8,
    type_changed,
};

const RawEntry = struct {
    status: RawStatus,
    old_mode: u32,
    new_mode: u32,
    old_oid: commit_diff.ObjectId,
    new_oid: commit_diff.ObjectId,
    old_path: []const u8,
    new_path: []const u8,
};

const NumstatKind = union(enum) {
    text: TextStats,
    binary,
};

const NumstatEntry = struct {
    kind: NumstatKind,
    renamed: bool,
    old_path: []const u8,
    new_path: []const u8,
};

const FileParseError = error{
    Malformed,
    TooManyFiles,
    PayloadTooLarge,
};

/// Verify one picker request against the repository's actual first-parent
/// graph, then read a generation-free preview from the derived exact basis.
pub fn readPreview(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    request: history.SelectionRequest,
) PreviewReadResult {
    return readPreviewObserved(allocator, io, context, request, null);
}

fn readPreviewObserved(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    request: history.SelectionRequest,
    command_counts: ?*PreviewCommandCounts,
) PreviewReadResult {
    var admission = admitSelection(
        allocator,
        io,
        context,
        request,
        selection_graph_limit,
        command_counts,
    );
    switch (admission) {
        .rejected => |terminal| return .{ .rejected = terminal },
        .verified => |*verified| {
            defer if (verified.root_object) |object| allocator.free(object);
            return .{ .verified = .{
                .summary = verified.summary,
                .payload = readPreviewFromSummaryObserved(
                    allocator,
                    io,
                    context,
                    verified.summary,
                    verified.root_object,
                    command_counts,
                ),
            } };
        },
    }
}

fn readPreviewFromSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    selection: SelectionSummary,
) PreviewPayload {
    return readPreviewFromSummaryObserved(allocator, io, context, selection, null, null);
}

fn readPreviewFromSummaryObserved(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    selection: SelectionSummary,
    root_object: ?[]const u8,
    command_counts: ?*PreviewCommandCounts,
) PreviewPayload {
    const admission = commit_diff.admitBasis(allocator, io, context, selection.basis()) catch
        return failedPayload(.allocation);
    switch (admission) {
        .admitted => {},
        .failure => |failure| return admissionFailurePayload(failure),
    }

    const detail: DetailResult = switch (selection) {
        .single => |single| (if (root_object) |object|
            readSingleDetailFromObject(allocator, io, context, single, object, command_counts)
        else
            readSingleDetail(allocator, io, context, single, command_counts)) catch
            .{ .failed = .allocation },
        .range => |range| .{ .ready = .{ .range = range } },
    };
    const files = readFiles(allocator, io, context, selection.basis(), command_counts) catch
        FilesResult{ .failed = .allocation };
    return .{ .detail = detail, .files = files };
}

const SelectionShape = struct {
    newest_index: usize,
    oldest_index: usize,
    newest_oid: commit_diff.ObjectId,
    oldest_oid: commit_diff.ObjectId,
    required_count: usize,
    is_single: bool,
};

const SelectionGraphRecord = struct {
    oid: commit_diff.ObjectId,
    parent_count: u32,
    first_parent: ?commit_diff.ObjectId,
};

const VerifiedSelection = struct {
    summary: SelectionSummary,
    root_object: ?[]u8 = null,
};

const SelectionAdmission = union(enum) {
    verified: VerifiedSelection,
    rejected: SelectionAdmissionTerminal,
};

fn validateSelectionRequest(request: history.SelectionRequest) ?SelectionShape {
    request.basis.validate() catch return null;
    const format = request.basis.object_format;
    if (!request.snapshot_head.validFor(format)) return null;
    return switch (request.intent) {
        .single => |single| blk: {
            if (single.index >= history.catalog_limit or
                !single.oid.validFor(format) or
                !single.oid.eql(&request.basis.after)) return null;
            const required_count = std.math.add(usize, single.index, 1) catch return null;
            break :blk .{
                .newest_index = single.index,
                .oldest_index = single.index,
                .newest_oid = single.oid,
                .oldest_oid = single.oid,
                .required_count = required_count,
                .is_single = true,
            };
        },
        .range => |range| blk: {
            if (range.anchor_index >= history.catalog_limit or
                range.cursor_index >= history.catalog_limit or
                range.newest_index >= history.catalog_limit or
                range.oldest_index >= history.catalog_limit or
                range.anchor_index == range.cursor_index or
                range.newest_index != @min(range.anchor_index, range.cursor_index) or
                range.oldest_index != @max(range.anchor_index, range.cursor_index) or
                range.newest_index >= range.oldest_index or
                !range.newest_oid.validFor(format) or
                !range.oldest_oid.validFor(format) or
                range.newest_oid.eql(&range.oldest_oid) or
                !range.newest_oid.eql(&request.basis.after)) return null;
            const required_count = std.math.add(usize, range.oldest_index, 1) catch return null;
            break :blk .{
                .newest_index = range.newest_index,
                .oldest_index = range.oldest_index,
                .newest_oid = range.newest_oid,
                .oldest_oid = range.oldest_oid,
                .required_count = required_count,
                .is_single = false,
            };
        },
    };
}

fn admitSelection(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    request: history.SelectionRequest,
    graph_output_limit: usize,
    command_counts: ?*PreviewCommandCounts,
) SelectionAdmission {
    const shape = validateSelectionRequest(request) orelse return .{ .rejected = .malformed };
    const records = allocator.alloc(SelectionGraphRecord, shape.required_count) catch
        return .{ .rejected = .{ .failed = .allocation } };
    defer allocator.free(records);

    var max_count_buffer: [32]u8 = undefined;
    const max_count = std.fmt.bufPrint(&max_count_buffer, "--max-count={d}", .{shape.required_count}) catch
        return .{ .rejected = .malformed };
    const prefix = commit_diff.strict_command_prefix;
    const argv = [_][]const u8{
        prefix[0],                     prefix[1],        prefix[2],   prefix[3],
        "rev-list",                    "--first-parent", "--parents", max_count,
        request.snapshot_head.slice(),
    };
    if (command_counts) |counts| counts.record(.selection_graph);
    var graph_result = git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(graph_output_limit),
        .stderr_limit = .limited(stderr_limit),
    }) catch return .{ .rejected = .{ .failed = .allocation } };
    defer graph_result.deinit(allocator);
    const graph = switch (graph_result) {
        .completed => |value| value,
        .stdout_limit_exceeded => return .{ .rejected = .{ .too_large = .selection_graph } },
        .stderr_limit_exceeded => return .{ .rejected = .{ .failed = .git_command } },
        .failed => |failure| return .{ .rejected = .{ .failed = if (failure.toError() == error.OutOfMemory)
            .allocation
        else
            .git_command } },
    };
    if (!termExited(graph.term, 0)) return .{ .rejected = .unavailable };
    if (!parseSelectionGraph(request.basis.object_format, graph.stdout, records) or
        !records[0].oid.eql(&request.snapshot_head)) return .{ .rejected = .malformed };
    for (records[0 .. records.len - 1], records[1..]) |record, next| {
        const first_parent = record.first_parent orelse return .{ .rejected = .malformed };
        if (!first_parent.eql(&next.oid)) return .{ .rejected = .malformed };
    }
    if (!records[shape.newest_index].oid.eql(&shape.newest_oid) or
        !records[shape.oldest_index].oid.eql(&shape.oldest_oid))
        return .{ .rejected = .malformed };

    var root_object: ?[]u8 = null;
    const before: commit_diff.Basis.Before = if (records[shape.oldest_index].first_parent) |parent|
        .{ .commit = parent }
    else blk: {
        const probe = probeRootCommit(
            allocator,
            io,
            context,
            request.basis.object_format,
            records[shape.oldest_index].oid,
            shape.is_single,
            command_counts,
        );
        switch (probe) {
            .root => |object| root_object = object,
            .rejected => |terminal| return .{ .rejected = terminal },
        }
        break :blk .empty_tree;
    };
    const derived_basis: commit_diff.Basis = .{
        .object_format = request.basis.object_format,
        .before = before,
        .after = records[shape.newest_index].oid,
    };
    if (!derived_basis.eql(request.basis)) {
        if (root_object) |object| allocator.free(object);
        return .{ .rejected = .malformed };
    }
    const summary: SelectionSummary = if (shape.is_single)
        .{ .single = .{
            .selected_oid = shape.newest_oid,
            .parent_count = records[shape.newest_index].parent_count,
            .basis = derived_basis,
        } }
    else
        .{ .range = .{
            .count = shape.oldest_index - shape.newest_index + 1,
            .oldest_oid = shape.oldest_oid,
            .newest_oid = shape.newest_oid,
            .basis = derived_basis,
        } };
    return .{ .verified = .{ .summary = summary, .root_object = root_object } };
}

fn parseSelectionGraph(
    format: commit_diff.ObjectFormat,
    bytes: []const u8,
    records: []SelectionGraphRecord,
) bool {
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return false;
    var record_index: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) return record_index == records.len and lines.next() == null;
        if (record_index >= records.len) return false;
        var fields = std.mem.splitScalar(u8, line, ' ');
        const oid_text = fields.next() orelse return false;
        if (oid_text.len == 0) return false;
        const oid = commit_diff.ObjectId.parse(format, oid_text) catch return false;
        var first_parent: ?commit_diff.ObjectId = null;
        var parent_count: u32 = 0;
        while (fields.next()) |parent_text| {
            if (parent_text.len == 0) return false;
            const parent = commit_diff.ObjectId.parse(format, parent_text) catch return false;
            if (parent_count == 0) first_parent = parent;
            parent_count = std.math.add(u32, parent_count, 1) catch return false;
        }
        records[record_index] = .{
            .oid = oid,
            .parent_count = parent_count,
            .first_parent = first_parent,
        };
        record_index += 1;
    }
    return false;
}

const RootProbe = union(enum) {
    root: ?[]u8,
    rejected: SelectionAdmissionTerminal,
};

fn probeRootCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: commit_diff.ObjectFormat,
    oid: commit_diff.ObjectId,
    keep_object: bool,
    command_counts: ?*PreviewCommandCounts,
) RootProbe {
    var stdin_buffer: [commit_diff.ObjectFormat.sha256.oidHexLength() + 1]u8 = undefined;
    @memcpy(stdin_buffer[0..oid.slice().len], oid.slice());
    stdin_buffer[oid.slice().len] = '\n';
    const prefix = commit_diff.strict_command_prefix;
    const argv = [_][]const u8{
        prefix[0], prefix[1], prefix[2], prefix[3], "cat-file", "--batch",
    };
    if (command_counts) |counts| counts.record(.root_probe);
    var result = git_command.runWithStdinBounded(allocator, io, context, .{
        .argv = &argv,
        .stdin = stdin_buffer[0 .. oid.slice().len + 1],
        .stdout_limit = .limited(commit_object_limit + commit_response_slack),
        .stderr_limit = .limited(stderr_limit),
    }) catch return .{ .rejected = .{ .failed = .allocation } };
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded => return .{ .rejected = .{ .too_large = .root_probe } },
        .stderr_limit_exceeded => return .{ .rejected = .{ .failed = .git_command } },
        .failed => |failure| return .{ .rejected = .{ .failed = if (failure.toError() == error.OutOfMemory)
            .allocation
        else
            .git_command } },
    };
    if (!termExited(completed.term, 0)) return .{ .rejected = .unavailable };
    const object = parseBatchCommitResponse(completed.stdout, &oid) orelse
        return .{ .rejected = .unavailable };
    if (object.len > commit_object_limit) return .{ .rejected = .{ .too_large = .root_probe } };
    const parent_count = parseCommitParentCount(format, object) orelse
        return .{ .rejected = .malformed };
    if (parent_count != 0) return .{ .rejected = .unavailable };
    if (!keep_object) return .{ .root = null };
    return .{ .root = allocator.dupe(u8, object) catch
        return .{ .rejected = .{ .failed = .allocation } } };
}

fn parseCommitParentCount(format: commit_diff.ObjectFormat, object: []const u8) ?u32 {
    const separator = std.mem.indexOf(u8, object, "\n\n") orelse return null;
    const headers = object[0..separator];
    var saw_tree = false;
    var previous_was_header = false;
    var parent_count: u32 = 0;
    var line_index: usize = 0;
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |line| : (line_index += 1) {
        if (line.len == 0 or std.mem.indexOfScalar(u8, line, 0) != null) return null;
        if (line[0] == ' ') {
            if (!previous_was_header) return null;
            continue;
        }
        previous_was_header = true;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
        if (space == 0 or space + 1 == line.len) return null;
        const key = line[0..space];
        const value = line[space + 1 ..];
        if (std.mem.eql(u8, key, "tree")) {
            if (saw_tree or line_index != 0) return null;
            _ = commit_diff.ObjectId.parse(format, value) catch return null;
            saw_tree = true;
        } else if (std.mem.eql(u8, key, "parent")) {
            _ = commit_diff.ObjectId.parse(format, value) catch return null;
            parent_count = std.math.add(u32, parent_count, 1) catch return null;
        }
    }
    return if (saw_tree) parent_count else null;
}

fn failedPayload(reason: FailureReason) PreviewPayload {
    return .{
        .detail = .{ .failed = reason },
        .files = .{ .failed = reason },
    };
}

fn admissionFailurePayload(failure: commit_diff.BasisAdmissionFailure) PreviewPayload {
    const unavailable: ?UnavailableReason = switch (failure) {
        .repository_format_drift => .repository_format_drift,
        .before_missing => .before_missing,
        .before_wrong_kind => .before_wrong_kind,
        .after_missing => .after_missing,
        .after_wrong_kind => .after_wrong_kind,
        .invalid_basis, .git_command_failed => null,
    };
    if (unavailable) |reason| return .{
        .detail = .{ .unavailable = reason },
        .files = .{ .unavailable = reason },
    };
    return failedPayload(if (failure == .invalid_basis) .malformed_output else .git_command);
}

fn readSingleDetail(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    summary: SingleSummary,
    command_counts: ?*PreviewCommandCounts,
) std.mem.Allocator.Error!DetailResult {
    if (!summary.selected_oid.eql(&summary.basis.after) or
        !summary.selected_oid.validFor(summary.basis.object_format))
        return .{ .failed = .malformed_output };

    var stdin_buffer: [commit_diff.ObjectFormat.sha256.oidHexLength() + 1]u8 = undefined;
    const oid = summary.selected_oid.slice();
    @memcpy(stdin_buffer[0..oid.len], oid);
    stdin_buffer[oid.len] = '\n';
    const prefix = commit_diff.strict_command_prefix;
    const argv = [_][]const u8{
        prefix[0], prefix[1], prefix[2], prefix[3], "cat-file", "--batch",
    };
    if (command_counts) |counts| counts.record(.commit_metadata);
    var result = try git_command.runWithStdinBounded(allocator, io, context, .{
        .argv = &argv,
        .stdin = stdin_buffer[0 .. oid.len + 1],
        .stdout_limit = .limited(commit_object_limit + commit_response_slack),
        .stderr_limit = .limited(stderr_limit),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded => return .{ .too_large = .commit_object },
        .stderr_limit_exceeded => return .{ .failed = .git_command },
        .failed => |failure| {
            if (failure.toError() == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failed = .git_command };
        },
    };
    if (!termExited(completed.term, 0)) return .{ .failed = .git_command };
    const object = parseBatchCommitResponse(completed.stdout, &summary.selected_oid) orelse
        return .{ .failed = .malformed_output };
    if (object.len > commit_object_limit) return .{ .too_large = .commit_object };

    return readSingleDetailFromObject(allocator, io, context, summary, object, command_counts);
}

fn readSingleDetailFromObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    summary: SingleSummary,
    object: []const u8,
    command_counts: ?*PreviewCommandCounts,
) std.mem.Allocator.Error!DetailResult {
    if (!summary.selected_oid.eql(&summary.basis.after) or
        !summary.selected_oid.validFor(summary.basis.object_format))
        return .{ .failed = .malformed_output };

    const view = parseCommitObject(object, summary) catch |err| return switch (err) {
        error.MetadataTooLarge => .{ .too_large = .metadata },
        error.MessageTooLarge => .{ .too_large = .message },
        error.IdentityTooLarge => .{ .too_large = .identity },
        error.Malformed => .{ .failed = .malformed_output },
    };

    var author = try ownIdentity(allocator, view.author_name, view.author_email);
    errdefer author.deinit(allocator);
    var committer = try ownIdentity(allocator, view.committer_name, view.committer_email);
    errdefer committer.deinit(allocator);
    const message = try dupeNonEmpty(allocator, view.message);
    errdefer if (message.len > 0) allocator.free(message);

    const refs_result = try readRefs(allocator, io, context, summary.selected_oid, command_counts);
    const refs = switch (refs_result) {
        .ready => |refs| refs,
        .too_large => {
            author.deinit(allocator);
            committer.deinit(allocator);
            if (message.len > 0) allocator.free(message);
            return .{ .too_large = .refs };
        },
        .failed => |reason| {
            author.deinit(allocator);
            committer.deinit(allocator);
            if (message.len > 0) allocator.free(message);
            return .{ .failed = reason };
        },
    };
    return .{ .ready = .{ .single = .{
        .summary = summary,
        .author = author,
        .authored = view.authored,
        .committer = committer,
        .committed = view.committed,
        .refs = refs,
        .message = message,
    } } };
}

fn parseBatchCommitResponse(bytes: []const u8, expected_oid: *const commit_diff.ObjectId) ?[]const u8 {
    const newline = std.mem.indexOfScalar(u8, bytes, '\n') orelse return null;
    const header = bytes[0..newline];
    var fields = std.mem.splitScalar(u8, header, ' ');
    const actual_oid = fields.next() orelse return null;
    const object_type = fields.next() orelse return null;
    const size_text = fields.next() orelse return null;
    if (fields.next() != null or
        !std.mem.eql(u8, actual_oid, expected_oid.slice()) or
        !std.mem.eql(u8, object_type, "commit")) return null;
    if (!allAsciiDigits(size_text)) return null;
    const size = std.fmt.parseInt(usize, size_text, 10) catch return null;
    const object_start = newline + 1;
    const remaining = bytes.len - object_start;
    if (remaining == 0 or size != remaining - 1) return null;
    if (bytes[bytes.len - 1] != '\n') return null;
    return bytes[object_start .. object_start + size];
}

fn parseCommitObject(object: []const u8, summary: SingleSummary) CommitParseError!CommitView {
    const separator = std.mem.indexOf(u8, object, "\n\n") orelse return error.Malformed;
    const headers = object[0..separator];
    const message = object[separator + 2 ..];
    if (headers.len > metadata_limit) return error.MetadataTooLarge;
    if (message.len > message_limit) return error.MessageTooLarge;
    if (!std.unicode.utf8ValidateSlice(message)) return error.Malformed;

    var author_line: ?[]const u8 = null;
    var committer_line: ?[]const u8 = null;
    var first_parent: ?commit_diff.ObjectId = null;
    var parent_count: u32 = 0;
    var saw_tree = false;
    var previous_was_header = false;
    var line_index: usize = 0;
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |line| : (line_index += 1) {
        if (line.len == 0 or std.mem.indexOfScalar(u8, line, 0) != null) return error.Malformed;
        if (line[0] == ' ') {
            if (!previous_was_header) return error.Malformed;
            continue;
        }
        previous_was_header = true;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.Malformed;
        if (space == 0 or space + 1 == line.len) return error.Malformed;
        const key = line[0..space];
        const value = line[space + 1 ..];
        if (std.mem.eql(u8, key, "tree")) {
            if (saw_tree or line_index != 0) return error.Malformed;
            _ = commit_diff.ObjectId.parse(summary.basis.object_format, value) catch return error.Malformed;
            saw_tree = true;
        } else if (std.mem.eql(u8, key, "parent")) {
            const parent = commit_diff.ObjectId.parse(summary.basis.object_format, value) catch return error.Malformed;
            if (parent_count == 0) first_parent = parent;
            parent_count = std.math.add(u32, parent_count, 1) catch return error.Malformed;
        } else if (std.mem.eql(u8, key, "author")) {
            if (author_line != null) return error.Malformed;
            author_line = value;
        } else if (std.mem.eql(u8, key, "committer")) {
            if (committer_line != null) return error.Malformed;
            committer_line = value;
        }
    }
    if (!saw_tree or author_line == null or committer_line == null or parent_count != summary.parent_count)
        return error.Malformed;
    switch (summary.basis.before) {
        .empty_tree => if (parent_count != 0) return error.Malformed,
        .commit => |before| {
            if (parent_count == 0 or !before.eql(&first_parent.?)) return error.Malformed;
        },
    }

    const author = try parseIdentityLine(author_line.?);
    const committer = try parseIdentityLine(committer_line.?);
    return .{
        .author_name = author.name,
        .author_email = author.email,
        .authored = author.timestamp,
        .committer_name = committer.name,
        .committer_email = committer.email,
        .committed = committer.timestamp,
        .message = message,
    };
}

const IdentityView = struct {
    name: []const u8,
    email: []const u8,
    timestamp: Timestamp,
};

fn parseIdentityLine(line: []const u8) CommitParseError!IdentityView {
    const timezone_space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return error.Malformed;
    if (timezone_space == 0 or timezone_space + 1 == line.len) return error.Malformed;
    const before_timezone = line[0..timezone_space];
    const unix_space = std.mem.lastIndexOfScalar(u8, before_timezone, ' ') orelse return error.Malformed;
    if (unix_space == 0 or unix_space + 1 == before_timezone.len) return error.Malformed;
    const identity = before_timezone[0..unix_space];
    if (identity.len < 3 or identity[identity.len - 1] != '>') return error.Malformed;
    const email_marker = std.mem.lastIndexOf(u8, identity, " <") orelse return error.Malformed;
    const name = identity[0..email_marker];
    const email = identity[email_marker + 2 .. identity.len - 1];
    if (name.len > identity_field_limit or email.len > identity_field_limit) return error.IdentityTooLarge;
    if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(email)) return error.Malformed;
    const unix_seconds = std.fmt.parseInt(i64, before_timezone[unix_space + 1 ..], 10) catch return error.Malformed;
    const timestamp = Timestamp.init(unix_seconds, line[timezone_space + 1 ..]) catch return error.Malformed;
    return .{ .name = name, .email = email, .timestamp = timestamp };
}

fn ownIdentity(allocator: std.mem.Allocator, name: []const u8, email: []const u8) std.mem.Allocator.Error!Identity {
    const owned_name = try dupeNonEmpty(allocator, name);
    errdefer if (owned_name.len > 0) allocator.free(owned_name);
    return .{
        .name = owned_name,
        .email = try dupeNonEmpty(allocator, email),
    };
}

fn dupeNonEmpty(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]const u8 {
    if (bytes.len == 0) return &.{};
    return allocator.dupe(u8, bytes);
}

fn readRefs(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: commit_diff.ObjectId,
    command_counts: ?*PreviewCommandCounts,
) std.mem.Allocator.Error!RefsReadResult {
    const prefix = commit_diff.strict_command_prefix;
    const format = "--format=%(refname)%00%(objecttype)%00%(objectname)%00%(*objecttype)%00%(*objectname)%00%(symref)%00";
    const argv = [_][]const u8{
        prefix[0],      prefix[1],        prefix[2], prefix[3],
        "for-each-ref", "--sort=refname", format,    "refs/heads",
        "refs/tags",    "refs/remotes",
    };
    if (command_counts) |counts| counts.record(.refs);
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(refs_output_limit),
        .stderr_limit = .limited(stderr_limit),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded => return .too_large,
        .stderr_limit_exceeded => return .{ .failed = .git_command },
        .failed => |failure| {
            if (failure.toError() == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failed = .git_command };
        },
    };
    if (!termExited(completed.term, 0)) return .{ .failed = .git_command };
    return parseRefs(allocator, completed.stdout, &target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooLarge => .too_large,
        error.Malformed => .{ .failed = .malformed_output },
    };
}

const RefParseError = error{ TooLarge, Malformed };

fn parseRefs(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    target: *const commit_diff.ObjectId,
) (std.mem.Allocator.Error || RefParseError)!RefsReadResult {
    var local: std.ArrayList([]const u8) = .empty;
    defer freeStringList(allocator, &local);
    var tags: std.ArrayList([]const u8) = .empty;
    defer freeStringList(allocator, &tags);
    var remotes: std.ArrayList([]const u8) = .empty;
    defer freeStringList(allocator, &remotes);

    if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') return error.Malformed;
    var count: usize = 0;
    var records = std.mem.splitScalar(u8, bytes, '\n');
    while (records.next()) |record| {
        if (record.len == 0) {
            if (records.peek() != null) return error.Malformed;
            break;
        }
        count += 1;
        if (count > ref_record_limit) return error.TooLarge;
        var fields = std.mem.splitScalar(u8, record, 0);
        const refname = fields.next() orelse return error.Malformed;
        const object_type = fields.next() orelse return error.Malformed;
        const object_name = fields.next() orelse return error.Malformed;
        const peeled_type = fields.next() orelse return error.Malformed;
        const peeled_name = fields.next() orelse return error.Malformed;
        const symref = fields.next() orelse return error.Malformed;
        const terminal = fields.next() orelse return error.Malformed;
        if (terminal.len != 0 or fields.next() != null or refname.len == 0) return error.Malformed;
        if (refname.len > ref_name_limit) return error.TooLarge;
        const object_format: commit_diff.ObjectFormat = switch (target.len) {
            commit_diff.ObjectFormat.sha1.oidHexLength() => .sha1,
            commit_diff.ObjectFormat.sha256.oidHexLength() => .sha256,
            else => return error.Malformed,
        };
        _ = commit_diff.ObjectId.parse(object_format, object_name) catch return error.Malformed;
        if ((peeled_type.len == 0) != (peeled_name.len == 0)) return error.Malformed;
        if (peeled_name.len > 0)
            _ = commit_diff.ObjectId.parse(object_format, peeled_name) catch return error.Malformed;
        if (symref.len > ref_name_limit) return error.TooLarge;

        if (std.mem.startsWith(u8, refname, "refs/heads/")) {
            if (refname.len == "refs/heads/".len) return error.Malformed;
            if (symref.len == 0 and std.mem.eql(u8, object_type, "commit") and
                std.mem.eql(u8, object_name, target.slice()))
                try appendOwnedRef(allocator, &local, refname["refs/heads/".len..]);
        } else if (std.mem.startsWith(u8, refname, "refs/remotes/")) {
            if (refname.len == "refs/remotes/".len) return error.Malformed;
            if (symref.len == 0 and std.mem.eql(u8, object_type, "commit") and
                std.mem.eql(u8, object_name, target.slice()))
                try appendOwnedRef(allocator, &remotes, refname["refs/remotes/".len..]);
        } else if (std.mem.startsWith(u8, refname, "refs/tags/")) {
            if (refname.len == "refs/tags/".len) return error.Malformed;
            if (symref.len != 0) continue;
            const direct = std.mem.eql(u8, object_type, "commit") and
                std.mem.eql(u8, object_name, target.slice());
            const peeled = std.mem.eql(u8, object_type, "tag") and
                std.mem.eql(u8, peeled_type, "commit") and
                std.mem.eql(u8, peeled_name, target.slice());
            if (direct or peeled)
                try appendOwnedRef(allocator, &tags, refname["refs/tags/".len..]);
        } else return error.Malformed;
    }

    std.mem.sort([]const u8, local.items, {}, stringLessThan);
    std.mem.sort([]const u8, tags.items, {}, stringLessThan);
    std.mem.sort([]const u8, remotes.items, {}, stringLessThan);
    const owned_local = try takeStringList(allocator, &local);
    errdefer freeOwnedStrings(allocator, owned_local);
    const owned_tags = try takeStringList(allocator, &tags);
    errdefer freeOwnedStrings(allocator, owned_tags);
    const owned_remotes = try takeStringList(allocator, &remotes);
    return .{ .ready = .{
        .local_branches = owned_local,
        .tags = owned_tags,
        .remote_branches = owned_remotes,
    } };
}

fn appendOwnedRef(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    short_name: []const u8,
) std.mem.Allocator.Error!void {
    if (short_name.len == 0) return;
    const owned = try allocator.dupe(u8, short_name);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

fn takeStringList(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
) std.mem.Allocator.Error![]const []const u8 {
    if (list.items.len == 0) return &.{};
    return list.toOwnedSlice(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn readFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    basis: commit_diff.Basis,
    command_counts: ?*PreviewCommandCounts,
) std.mem.Allocator.Error!FilesResult {
    const raw_capture = try captureProjection(allocator, io, context, basis, .raw_z, raw_output_limit, command_counts);
    const raw_bytes = switch (raw_capture) {
        .bytes => |bytes| bytes,
        .too_large => return .{ .too_large = .raw },
        .failed => return .{ .failed = .git_command },
    };
    defer allocator.free(raw_bytes);

    const numstat_capture = try captureProjection(allocator, io, context, basis, .numstat_z, numstat_output_limit, command_counts);
    const numstat_bytes = switch (numstat_capture) {
        .bytes => |bytes| bytes,
        .too_large => return .{ .too_large = .numstat },
        .failed => return .{ .failed = .git_command },
    };
    defer allocator.free(numstat_bytes);

    const raw_entries = parseRawEntries(allocator, raw_bytes, basis.object_format) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooManyFiles, error.PayloadTooLarge => .{ .too_large = .file_list },
        error.Malformed => .{ .failed = .malformed_output },
    };
    defer if (raw_entries.len > 0) allocator.free(raw_entries);
    const numstat_entries = parseNumstatEntries(allocator, numstat_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooManyFiles, error.PayloadTooLarge => .{ .too_large = .file_list },
        error.Malformed => .{ .failed = .malformed_output },
    };
    defer if (numstat_entries.len > 0) allocator.free(numstat_entries);

    return reconcileFileEntries(allocator, raw_entries, numstat_entries) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooManyFiles, error.PayloadTooLarge => .{ .too_large = .file_list },
        error.Malformed => .{ .failed = .malformed_output },
    };
}

fn captureProjection(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    basis: commit_diff.Basis,
    projection: commit_diff.DiffProjection,
    output_limit: usize,
    command_counts: ?*PreviewCommandCounts,
) std.mem.Allocator.Error!ProjectionCapture {
    var command = commit_diff.buildDiffCommand(allocator, basis, projection) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBasis => return .failed,
    };
    defer command.deinit(allocator);
    if (command_counts) |counts| counts.record(switch (projection) {
        .raw_z => .raw,
        .numstat_z => .numstat,
        else => unreachable,
    });
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = command.argv,
        .stdout_limit = .limited(output_limit),
        .stderr_limit = .limited(stderr_limit),
    });
    return switch (result) {
        .stdout_limit_exceeded => .too_large,
        .stderr_limit_exceeded => .failed,
        .failed => |*failure| blk: {
            if (failure.toError() == error.OutOfMemory) {
                failure.deinit(allocator);
                return error.OutOfMemory;
            }
            failure.deinit(allocator);
            break :blk .failed;
        },
        .completed => |completed| blk: {
            if (!termExited(completed.term, 0)) {
                completed.deinit(allocator);
                break :blk .failed;
            }
            allocator.free(completed.stderr);
            break :blk .{ .bytes = completed.stdout };
        },
    };
}

fn parseRawEntries(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    format: commit_diff.ObjectFormat,
) (std.mem.Allocator.Error || FileParseError)![]RawEntry {
    var entries: std.ArrayList(RawEntry) = .empty;
    defer entries.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const header = takeNul(bytes, &cursor) orelse return error.Malformed;
        if (header.len < 2 or header[0] != ':') return error.Malformed;
        var fields = std.mem.splitScalar(u8, header[1..], ' ');
        const old_mode_text = fields.next() orelse return error.Malformed;
        const new_mode_text = fields.next() orelse return error.Malformed;
        const old_oid_text = fields.next() orelse return error.Malformed;
        const new_oid_text = fields.next() orelse return error.Malformed;
        const status_text = fields.next() orelse return error.Malformed;
        if (fields.next() != null or old_mode_text.len != 6 or new_mode_text.len != 6) return error.Malformed;
        if (!allAsciiOctalDigits(old_mode_text) or !allAsciiOctalDigits(new_mode_text)) return error.Malformed;
        const old_mode = std.fmt.parseInt(u32, old_mode_text, 8) catch return error.Malformed;
        const new_mode = std.fmt.parseInt(u32, new_mode_text, 8) catch return error.Malformed;
        const old_oid = commit_diff.ObjectId.parse(format, old_oid_text) catch return error.Malformed;
        const new_oid = commit_diff.ObjectId.parse(format, new_oid_text) catch return error.Malformed;
        const status = try parseRawStatus(status_text);
        const old_path = takeNul(bytes, &cursor) orelse return error.Malformed;
        if (old_path.len == 0) return error.Malformed;
        const new_path = switch (status) {
            .renamed => takeNul(bytes, &cursor) orelse return error.Malformed,
            else => old_path,
        };
        if (new_path.len == 0) return error.Malformed;
        if (!validRawEntry(status, old_mode, new_mode, &old_oid, &new_oid)) return error.Malformed;
        if (entries.items.len == file_count_limit) return error.TooManyFiles;
        try entries.append(allocator, .{
            .status = status,
            .old_mode = old_mode,
            .new_mode = new_mode,
            .old_oid = old_oid,
            .new_oid = new_oid,
            .old_path = old_path,
            .new_path = new_path,
        });
    }
    if (entries.items.len == 0) return &.{};
    return entries.toOwnedSlice(allocator);
}

fn parseRawStatus(text: []const u8) FileParseError!RawStatus {
    if (text.len == 1) return switch (text[0]) {
        'M' => .modified,
        'A' => .added,
        'D' => .deleted,
        'T' => .type_changed,
        'C' => error.Malformed,
        else => error.Malformed,
    };
    if (text.len == 4 and text[0] == 'R') {
        if (!allAsciiDigits(text[1..])) return error.Malformed;
        const similarity = std.fmt.parseInt(u8, text[1..], 10) catch return error.Malformed;
        if (similarity > 100) return error.Malformed;
        return .{ .renamed = similarity };
    }
    // Copies are disabled by the shared committed-diff policy. Seeing one is
    // a policy or output violation, never a second path shape.
    return error.Malformed;
}

fn parseNumstatEntries(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) (std.mem.Allocator.Error || FileParseError)![]NumstatEntry {
    var entries: std.ArrayList(NumstatEntry) = .empty;
    defer entries.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const added_end = indexFrom(bytes, cursor, '\t') orelse return error.Malformed;
        const added_text = bytes[cursor..added_end];
        cursor = added_end + 1;
        const removed_end = indexFrom(bytes, cursor, '\t') orelse return error.Malformed;
        const removed_text = bytes[cursor..removed_end];
        cursor = removed_end + 1;
        const kind: NumstatKind = if (std.mem.eql(u8, added_text, "-") and
            std.mem.eql(u8, removed_text, "-"))
            .binary
        else blk: {
            if (std.mem.eql(u8, added_text, "-") or std.mem.eql(u8, removed_text, "-"))
                return error.Malformed;
            break :blk .{ .text = .{
                .added = parseDecimalCount(added_text) orelse return error.Malformed,
                .removed = parseDecimalCount(removed_text) orelse return error.Malformed,
            } };
        };

        var old_path: []const u8 = undefined;
        var new_path: []const u8 = undefined;
        var renamed = false;
        if (cursor < bytes.len and bytes[cursor] == 0) {
            cursor += 1;
            renamed = true;
            old_path = takeNul(bytes, &cursor) orelse return error.Malformed;
            new_path = takeNul(bytes, &cursor) orelse return error.Malformed;
        } else {
            old_path = takeNul(bytes, &cursor) orelse return error.Malformed;
            new_path = old_path;
        }
        if (old_path.len == 0 or new_path.len == 0) return error.Malformed;
        if (entries.items.len == file_count_limit) return error.TooManyFiles;
        try entries.append(allocator, .{
            .kind = kind,
            .renamed = renamed,
            .old_path = old_path,
            .new_path = new_path,
        });
    }
    if (entries.items.len == 0) return &.{};
    return entries.toOwnedSlice(allocator);
}

fn reconcileFileEntries(
    allocator: std.mem.Allocator,
    raw_entries: []RawEntry,
    numstat_entries: []NumstatEntry,
) (std.mem.Allocator.Error || FileParseError)!FilesResult {
    if (raw_entries.len != numstat_entries.len) return error.Malformed;
    std.mem.sort(RawEntry, raw_entries, {}, rawEntryLessThan);
    std.mem.sort(NumstatEntry, numstat_entries, {}, numstatEntryLessThan);

    var payload_bytes = raw_entries.len * @sizeOf(FileChange);
    if (payload_bytes > file_payload_limit) return error.PayloadTooLarge;
    for (raw_entries, numstat_entries, 0..) |raw, numstat, index| {
        if (!sameTuple(raw.old_path, raw.new_path, numstat.old_path, numstat.new_path))
            return error.Malformed;
        if ((raw.status == .renamed) != numstat.renamed) return error.Malformed;
        if (index > 0 and sameTuple(
            raw_entries[index - 1].old_path,
            raw_entries[index - 1].new_path,
            raw.old_path,
            raw.new_path,
        )) return error.Malformed;
        const path_bytes = switch (raw.status) {
            .renamed => raw.old_path.len + raw.new_path.len,
            else => raw.new_path.len,
        };
        if (path_bytes > file_payload_limit - payload_bytes) return error.PayloadTooLarge;
        payload_bytes += path_bytes;
    }

    if (raw_entries.len == 0) return .{ .ready = &.{} };
    const changes = try allocator.alloc(FileChange, raw_entries.len);
    var initialized: usize = 0;
    errdefer {
        for (changes[0..initialized]) |*change| change.deinit(allocator);
        allocator.free(changes);
    }
    for (raw_entries, numstat_entries, 0..) |raw, numstat, index| {
        changes[index] = .{
            .kind = try ownFileKind(allocator, raw),
            .old_mode = raw.old_mode,
            .new_mode = raw.new_mode,
            .old_oid = raw.old_oid,
            .new_oid = raw.new_oid,
            .stats = classifyStats(raw, numstat.kind),
        };
        initialized += 1;
    }
    std.mem.sort(FileChange, changes, {}, fileChangeLessThan);
    return .{ .ready = changes };
}

fn ownFileKind(allocator: std.mem.Allocator, raw: RawEntry) std.mem.Allocator.Error!FileChangeKind {
    return switch (raw.status) {
        .modified => .{ .modified = try allocator.dupe(u8, raw.new_path) },
        .added => .{ .added = try allocator.dupe(u8, raw.new_path) },
        .deleted => .{ .deleted = try allocator.dupe(u8, raw.new_path) },
        .type_changed => .{ .type_changed = try allocator.dupe(u8, raw.new_path) },
        .renamed => |similarity| blk: {
            const old = try allocator.dupe(u8, raw.old_path);
            errdefer allocator.free(old);
            break :blk .{ .renamed = .{
                .similarity = similarity,
                .old = old,
                .new = try allocator.dupe(u8, raw.new_path),
            } };
        },
    };
}

fn classifyStats(raw: RawEntry, numstat: NumstatKind) StatsKind {
    if (raw.old_mode == 0o160000 or raw.new_mode == 0o160000) return .submodule;
    return switch (numstat) {
        .binary => .binary,
        .text => |stats| if (raw.old_mode != raw.new_mode and raw.old_oid.eql(&raw.new_oid))
            .mode_only
        else
            .{ .text = stats },
    };
}

fn rawEntryLessThan(_: void, left: RawEntry, right: RawEntry) bool {
    return tupleOrder(left.old_path, left.new_path, right.old_path, right.new_path) == .lt;
}

fn numstatEntryLessThan(_: void, left: NumstatEntry, right: NumstatEntry) bool {
    return tupleOrder(left.old_path, left.new_path, right.old_path, right.new_path) == .lt;
}

fn tupleOrder(left_old: []const u8, left_new: []const u8, right_old: []const u8, right_new: []const u8) std.math.Order {
    const old_order = std.mem.order(u8, left_old, right_old);
    if (old_order != .eq) return old_order;
    return std.mem.order(u8, left_new, right_new);
}

fn sameTuple(left_old: []const u8, left_new: []const u8, right_old: []const u8, right_new: []const u8) bool {
    return std.mem.eql(u8, left_old, right_old) and std.mem.eql(u8, left_new, right_new);
}

fn validRawEntry(
    status: RawStatus,
    old_mode: u32,
    new_mode: u32,
    old_oid: *const commit_diff.ObjectId,
    new_oid: *const commit_diff.ObjectId,
) bool {
    if (!validGitMode(old_mode) or !validGitMode(new_mode)) return false;
    const old_zero = isZeroOid(old_oid);
    const new_zero = isZeroOid(new_oid);
    return switch (status) {
        .added => old_mode == 0 and old_zero and new_mode != 0 and !new_zero,
        .deleted => old_mode != 0 and !old_zero and new_mode == 0 and new_zero,
        .modified, .renamed => old_mode != 0 and new_mode != 0 and !old_zero and !new_zero,
        .type_changed => old_mode != 0 and new_mode != 0 and old_mode != new_mode and !old_zero and !new_zero,
    };
}

fn validGitMode(mode: u32) bool {
    return switch (mode) {
        0, 0o100644, 0o100755, 0o120000, 0o160000 => true,
        else => false,
    };
}

fn isZeroOid(oid: *const commit_diff.ObjectId) bool {
    for (oid.slice()) |byte| if (byte != '0') return false;
    return true;
}

fn parseDecimalCount(text: []const u8) ?u64 {
    if (!allAsciiDigits(text)) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn allAsciiDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn allAsciiOctalDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| if (byte < '0' or byte > '7') return false;
    return true;
}

fn indexFrom(bytes: []const u8, start: usize, needle: u8) ?usize {
    const relative = std.mem.indexOfScalar(u8, bytes[start..], needle) orelse return null;
    return start + relative;
}

fn takeNul(bytes: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* > bytes.len) return null;
    const end = indexFrom(bytes, cursor.*, 0) orelse return null;
    const value = bytes[cursor.*..end];
    cursor.* = end + 1;
    return value;
}

fn termExited(term: std.process.Child.Term, expected: u8) bool {
    return switch (term) {
        .exited => |code| code == expected,
        else => false,
    };
}

fn freeOwnedStrings(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| if (item.len > 0) allocator.free(item);
    if (items.len > 0) allocator.free(items);
}

fn testOid(text: []const u8) !commit_diff.ObjectId {
    return commit_diff.ObjectId.parse(.sha1, text);
}

fn testOwnedStrings(values: []const []const u8) ![]const []const u8 {
    const owned = try std.testing.allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(owned);
    }
    for (values, 0..) |value, index| {
        owned[index] = try std.testing.allocator.dupe(u8, value);
        initialized += 1;
    }
    return owned;
}

fn testIdentity(name: []const u8, email: []const u8) !Identity {
    const owned_name = try std.testing.allocator.dupe(u8, name);
    errdefer std.testing.allocator.free(owned_name);
    const owned_email = try std.testing.allocator.dupe(u8, email);
    return .{ .name = owned_name, .email = owned_email };
}

test "History preview parses exact commit identities parents and message" {
    const parent = try testOid("1111111111111111111111111111111111111111");
    const selected = try testOid("2222222222222222222222222222222222222222");
    const summary: SingleSummary = .{
        .selected_oid = selected,
        .parent_count = 1,
        .basis = .{ .object_format = .sha1, .before = .{ .commit = parent }, .after = selected },
    };
    const object =
        "tree 3333333333333333333333333333333333333333\n" ++
        "parent 1111111111111111111111111111111111111111\n" ++
        "author Author Name <author@example.invalid> -42 +0530\n" ++
        "committer Committer Name <committer@example.invalid> 123 -0230\n" ++
        "gpgsig signature\n continuation\n" ++
        "\nsubject\n\nbody\n";
    const view = try parseCommitObject(object, summary);
    try std.testing.expectEqualStrings("Author Name", view.author_name);
    try std.testing.expectEqualStrings("author@example.invalid", view.author_email);
    try std.testing.expectEqual(@as(i64, -42), view.authored.unix_seconds);
    try std.testing.expectEqual(@as(i16, 330), view.authored.offset_minutes);
    try std.testing.expectEqualStrings("Committer Name", view.committer_name);
    try std.testing.expectEqualStrings("committer@example.invalid", view.committer_email);
    try std.testing.expectEqual(@as(i16, -150), view.committed.offset_minutes);
    try std.testing.expectEqualStrings("subject\n\nbody\n", view.message);

    const root_summary: SingleSummary = .{
        .selected_oid = selected,
        .parent_count = 0,
        .basis = .{ .object_format = .sha1, .before = .empty_tree, .after = selected },
    };
    try std.testing.expectError(error.Malformed, parseCommitObject(object, root_summary));
    const invalid_utf8 =
        "tree 3333333333333333333333333333333333333333\n" ++
        "author A <a@example.invalid> 1 +0000\n" ++
        "committer C <c@example.invalid> 2 +0000\n\n\xff";
    try std.testing.expectError(error.Malformed, parseCommitObject(invalid_utf8, root_summary));
}

test "History preview parses and sorts typed refs for one exact commit" {
    const target = try testOid("2222222222222222222222222222222222222222");
    const other = "1111111111111111111111111111111111111111";
    const bytes =
        "refs/heads/zeta\x00commit\x002222222222222222222222222222222222222222\x00\x00\x00\x00\n" ++
        "refs/heads/alpha\x00commit\x002222222222222222222222222222222222222222\x00\x00\x00\x00\n" ++
        "refs/heads/other\x00commit\x00" ++ other ++ "\x00\x00\x00\x00\n" ++
        "refs/remotes/origin/main\x00commit\x002222222222222222222222222222222222222222\x00\x00\x00\x00\n" ++
        "refs/remotes/origin/HEAD\x00commit\x002222222222222222222222222222222222222222\x00\x00\x00refs/remotes/origin/main\x00\n" ++
        "refs/tags/v1-light\x00commit\x002222222222222222222222222222222222222222\x00\x00\x00\x00\n" ++
        "refs/tags/v2-annotated\x00tag\x00" ++ other ++ "\x00commit\x002222222222222222222222222222222222222222\x00\x00\n";
    const parsed = try parseRefs(std.testing.allocator, bytes, &target);
    var refs = switch (parsed) {
        .ready => |refs| refs,
        else => return error.ExpectedReadyRefs,
    };
    defer refs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), refs.local_branches.len);
    try std.testing.expectEqualStrings("alpha", refs.local_branches[0]);
    try std.testing.expectEqualStrings("zeta", refs.local_branches[1]);
    try std.testing.expectEqual(@as(usize, 2), refs.tags.len);
    try std.testing.expectEqualStrings("v1-light", refs.tags[0]);
    try std.testing.expectEqualStrings("v2-annotated", refs.tags[1]);
    try std.testing.expectEqual(@as(usize, 1), refs.remote_branches.len);
    try std.testing.expectEqualStrings("origin/main", refs.remote_branches[0]);
}

test "History preview reconciles raw and numstat by path tuple" {
    const one = "1111111111111111111111111111111111111111";
    const two = "2222222222222222222222222222222222222222";
    const zero = "0000000000000000000000000000000000000000";
    const special = "tab\tline\nbad\xff";
    const raw =
        ":100644 100644 " ++ one ++ " " ++ two ++ " R075\x00old-name\x00z-new\x00" ++
        ":100644 100644 " ++ one ++ " " ++ two ++ " M\x00" ++ special ++ "\x00" ++
        ":100644 100644 " ++ one ++ " " ++ two ++ " M\x00binary.dat\x00" ++
        ":100644 100755 " ++ one ++ " " ++ one ++ " M\x00mode-only\x00" ++
        ":160000 160000 " ++ one ++ " " ++ two ++ " M\x00submodule\x00" ++
        ":000000 100644 " ++ zero ++ " " ++ two ++ " A\x00added\x00" ++
        ":100644 000000 " ++ one ++ " " ++ zero ++ " D\x00deleted\x00" ++
        ":100644 120000 " ++ one ++ " " ++ two ++ " T\x00type-change\x00";
    // Deliberately reverse most numstat records: reconciliation must not use
    // projection position.
    const numstat =
        "1\t2\ttype-change\x00" ++
        "0\t3\tdeleted\x00" ++
        "4\t0\tadded\x00" ++
        "1\t1\tsubmodule\x00" ++
        "0\t0\tmode-only\x00" ++
        "-\t-\tbinary.dat\x00" ++
        "5\t6\t" ++ special ++ "\x00" ++
        "3\t4\t\x00old-name\x00z-new\x00";
    const raw_entries = try parseRawEntries(std.testing.allocator, raw, .sha1);
    defer std.testing.allocator.free(raw_entries);
    const numstat_entries = try parseNumstatEntries(std.testing.allocator, numstat);
    defer std.testing.allocator.free(numstat_entries);
    var result = try reconcileFileEntries(std.testing.allocator, raw_entries, numstat_entries);
    defer result.deinit(std.testing.allocator);
    const changes = switch (result) {
        .ready => |changes| changes,
        else => return error.ExpectedReadyFiles,
    };
    try std.testing.expectEqual(@as(usize, 8), changes.len);
    var saw_special = false;
    var saw_rename = false;
    var saw_binary = false;
    var saw_mode = false;
    var saw_submodule = false;
    for (changes) |change| {
        if (std.mem.eql(u8, change.canonicalPath(), special)) {
            saw_special = true;
            try std.testing.expectEqualDeep(StatsKind{ .text = .{ .added = 5, .removed = 6 } }, change.stats);
        } else if (std.mem.eql(u8, change.canonicalPath(), "z-new")) {
            saw_rename = true;
            try std.testing.expectEqual(@as(?u8, 75), change.renameSimilarity());
        } else if (std.mem.eql(u8, change.canonicalPath(), "binary.dat")) {
            saw_binary = change.stats == .binary;
        } else if (std.mem.eql(u8, change.canonicalPath(), "mode-only")) {
            saw_mode = change.stats == .mode_only;
        } else if (std.mem.eql(u8, change.canonicalPath(), "submodule")) {
            saw_submodule = change.stats == .submodule;
        }
    }
    try std.testing.expect(saw_special and saw_rename and saw_binary and saw_mode and saw_submodule);

    const copy_raw = ":100644 100644 " ++ one ++ " " ++ two ++ " C100\x00old\x00new\x00";
    try std.testing.expectError(error.Malformed, parseRawEntries(std.testing.allocator, copy_raw, .sha1));

    const oid_one = try testOid(one);
    const oid_two = try testOid(two);
    var shape_raw = [_]RawEntry{.{
        .status = .modified,
        .old_mode = 0o100644,
        .new_mode = 0o100644,
        .old_oid = oid_one,
        .new_oid = oid_two,
        .old_path = "same",
        .new_path = "same",
    }};
    var shape_numstat = [_]NumstatEntry{.{
        .kind = .{ .text = .{ .added = 1, .removed = 1 } },
        .renamed = true,
        .old_path = "same",
        .new_path = "same",
    }};
    try std.testing.expectError(error.Malformed, reconcileFileEntries(std.testing.allocator, &shape_raw, &shape_numstat));
}

test "History preview parsers release every partial allocation" {
    const target = try testOid("2222222222222222222222222222222222222222");
    const refs_bytes =
        "refs/heads/main\x00commit\x002222222222222222222222222222222222222222\x00\x00\x00\x00\n" ++
        "refs/tags/v1\x00commit\x002222222222222222222222222222222222222222\x00\x00\x00\x00\n" ++
        "refs/remotes/origin/main\x00commit\x002222222222222222222222222222222222222222\x00\x00\x00\x00\n";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn parse(allocator: std.mem.Allocator, bytes: []const u8, oid: commit_diff.ObjectId) !void {
            var result = try parseRefs(allocator, bytes, &oid);
            switch (result) {
                .ready => |*refs| refs.deinit(allocator),
                else => return error.ExpectedReadyRefs,
            }
        }
    }.parse, .{ refs_bytes, target });

    const one = try testOid("1111111111111111111111111111111111111111");
    const raw = [_]RawEntry{
        .{
            .status = .{ .renamed = 80 },
            .old_mode = 0o100644,
            .new_mode = 0o100644,
            .old_oid = one,
            .new_oid = target,
            .old_path = "old",
            .new_path = "new",
        },
        .{
            .status = .modified,
            .old_mode = 0o100644,
            .new_mode = 0o100644,
            .old_oid = one,
            .new_oid = target,
            .old_path = "plain",
            .new_path = "plain",
        },
    };
    const numstat = [_]NumstatEntry{
        .{
            .kind = .{ .text = .{ .added = 1, .removed = 2 } },
            .renamed = true,
            .old_path = "old",
            .new_path = "new",
        },
        .{
            .kind = .binary,
            .renamed = false,
            .old_path = "plain",
            .new_path = "plain",
        },
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn reconcile(allocator: std.mem.Allocator, raw_source: []const RawEntry, numstat_source: []const NumstatEntry) !void {
            const raw_copy = try allocator.dupe(RawEntry, raw_source);
            defer allocator.free(raw_copy);
            const numstat_copy = try allocator.dupe(NumstatEntry, numstat_source);
            defer allocator.free(numstat_copy);
            var result = try reconcileFileEntries(allocator, raw_copy, numstat_copy);
            result.deinit(allocator);
        }
    }.reconcile, .{ &raw, &numstat });
}

test "History preview parser limits accept exact boundaries and reject the next byte or record" {
    const allocator = std.testing.allocator;
    const selected = try testOid("2222222222222222222222222222222222222222");
    const root_summary: SingleSummary = .{
        .selected_oid = selected,
        .parent_count = 0,
        .basis = .{ .object_format = .sha1, .before = .empty_tree, .after = selected },
    };
    const base_headers =
        "tree 3333333333333333333333333333333333333333\n" ++
        "author A <a@example.invalid> 1 +0000\n" ++
        "committer C <c@example.invalid> 2 +0000";

    const exact_message_object = try allocator.alloc(u8, base_headers.len + 2 + message_limit);
    defer allocator.free(exact_message_object);
    @memcpy(exact_message_object[0..base_headers.len], base_headers);
    @memcpy(exact_message_object[base_headers.len .. base_headers.len + 2], "\n\n");
    @memset(exact_message_object[base_headers.len + 2 ..], 'm');
    try std.testing.expectEqual(@as(usize, message_limit), (try parseCommitObject(exact_message_object, root_summary)).message.len);
    const oversized_message_object = try allocator.alloc(u8, exact_message_object.len + 1);
    defer allocator.free(oversized_message_object);
    @memcpy(oversized_message_object[0..exact_message_object.len], exact_message_object);
    oversized_message_object[oversized_message_object.len - 1] = 'm';
    try std.testing.expectError(error.MessageTooLarge, parseCommitObject(oversized_message_object, root_summary));

    const metadata_prefix = base_headers ++ "\nextra ";
    const exact_metadata_object = try allocator.alloc(u8, metadata_limit + 2);
    defer allocator.free(exact_metadata_object);
    @memcpy(exact_metadata_object[0..metadata_prefix.len], metadata_prefix);
    @memset(exact_metadata_object[metadata_prefix.len..metadata_limit], 'x');
    @memcpy(exact_metadata_object[metadata_limit..], "\n\n");
    _ = try parseCommitObject(exact_metadata_object, root_summary);
    const oversized_metadata_object = try allocator.alloc(u8, metadata_limit + 3);
    defer allocator.free(oversized_metadata_object);
    @memcpy(oversized_metadata_object[0..metadata_limit], exact_metadata_object[0..metadata_limit]);
    oversized_metadata_object[metadata_limit] = 'x';
    @memcpy(oversized_metadata_object[metadata_limit + 1 ..], "\n\n");
    try std.testing.expectError(error.MetadataTooLarge, parseCommitObject(oversized_metadata_object, root_summary));

    const exact_name = try allocator.alloc(u8, identity_field_limit);
    defer allocator.free(exact_name);
    @memset(exact_name, 'n');
    const exact_identity_object = try std.fmt.allocPrint(
        allocator,
        "tree 3333333333333333333333333333333333333333\nauthor {s} <a@example.invalid> 1 +0000\ncommitter C <c@example.invalid> 2 +0000\n\n",
        .{exact_name},
    );
    defer allocator.free(exact_identity_object);
    try std.testing.expectEqual(@as(usize, identity_field_limit), (try parseCommitObject(exact_identity_object, root_summary)).author_name.len);
    const oversized_name = try allocator.alloc(u8, identity_field_limit + 1);
    defer allocator.free(oversized_name);
    @memset(oversized_name, 'n');
    const oversized_identity_object = try std.fmt.allocPrint(
        allocator,
        "tree 3333333333333333333333333333333333333333\nauthor {s} <a@example.invalid> 1 +0000\ncommitter C <c@example.invalid> 2 +0000\n\n",
        .{oversized_name},
    );
    defer allocator.free(oversized_identity_object);
    try std.testing.expectError(error.IdentityTooLarge, parseCommitObject(oversized_identity_object, root_summary));

    const ref_suffix = try allocator.alloc(u8, ref_name_limit - "refs/heads/".len);
    defer allocator.free(ref_suffix);
    @memset(ref_suffix, 'r');
    const exact_ref_record = try std.fmt.allocPrint(
        allocator,
        "refs/heads/{s}\x00commit\x00{s}\x00\x00\x00\x00\n",
        .{ ref_suffix, selected.slice() },
    );
    defer allocator.free(exact_ref_record);
    var exact_refs_result = try parseRefs(allocator, exact_ref_record, &selected);
    switch (exact_refs_result) {
        .ready => |*refs| refs.deinit(allocator),
        else => return error.ExpectedReadyRefs,
    }
    const oversized_ref_record = try std.fmt.allocPrint(
        allocator,
        "refs/heads/{s}x\x00commit\x00{s}\x00\x00\x00\x00\n",
        .{ ref_suffix, selected.slice() },
    );
    defer allocator.free(oversized_ref_record);
    try std.testing.expectError(error.TooLarge, parseRefs(allocator, oversized_ref_record, &selected));

    var ref_records: std.Io.Writer.Allocating = .init(allocator);
    defer ref_records.deinit();
    for (0..ref_record_limit) |_| try ref_records.writer.print(
        "refs/heads/r\x00commit\x00{s}\x00\x00\x00\x00\n",
        .{selected.slice()},
    );
    var exact_count_result = try parseRefs(allocator, ref_records.written(), &selected);
    switch (exact_count_result) {
        .ready => |*refs| refs.deinit(allocator),
        else => return error.ExpectedReadyRefs,
    }
    try ref_records.writer.print(
        "refs/heads/r\x00commit\x00{s}\x00\x00\x00\x00\n",
        .{selected.slice()},
    );
    try std.testing.expectError(error.TooLarge, parseRefs(allocator, ref_records.written(), &selected));

    const one = "1111111111111111111111111111111111111111";
    var raw_records: std.Io.Writer.Allocating = .init(allocator);
    defer raw_records.deinit();
    for (0..file_count_limit) |index| try raw_records.writer.print(
        ":100644 100644 {s} {s} M\x00p{d}\x00",
        .{ one, selected.slice(), index },
    );
    const exact_raw_entries = try parseRawEntries(allocator, raw_records.written(), .sha1);
    defer allocator.free(exact_raw_entries);
    try std.testing.expectEqual(@as(usize, file_count_limit), exact_raw_entries.len);
    try raw_records.writer.print(
        ":100644 100644 {s} {s} M\x00overflow\x00",
        .{ one, selected.slice() },
    );
    try std.testing.expectError(error.TooManyFiles, parseRawEntries(allocator, raw_records.written(), .sha1));

    const oid = try testOid(one);
    const exact_path_len = file_payload_limit - @sizeOf(FileChange);
    const exact_path = try allocator.alloc(u8, exact_path_len);
    defer allocator.free(exact_path);
    @memset(exact_path, 'p');
    var exact_raw = [_]RawEntry{.{
        .status = .modified,
        .old_mode = 0o100644,
        .new_mode = 0o100644,
        .old_oid = oid,
        .new_oid = selected,
        .old_path = exact_path,
        .new_path = exact_path,
    }};
    var exact_numstat = [_]NumstatEntry{.{
        .kind = .{ .text = .{ .added = 1, .removed = 1 } },
        .renamed = false,
        .old_path = exact_path,
        .new_path = exact_path,
    }};
    var exact_payload = try reconcileFileEntries(allocator, &exact_raw, &exact_numstat);
    exact_payload.deinit(allocator);
    const oversized_path = try allocator.alloc(u8, exact_path_len + 1);
    defer allocator.free(oversized_path);
    @memset(oversized_path, 'p');
    var oversized_raw = exact_raw;
    oversized_raw[0].old_path = oversized_path;
    oversized_raw[0].new_path = oversized_path;
    var oversized_numstat = exact_numstat;
    oversized_numstat[0].old_path = oversized_path;
    oversized_numstat[0].new_path = oversized_path;
    try std.testing.expectError(error.PayloadTooLarge, reconcileFileEntries(allocator, &oversized_raw, &oversized_numstat));
}

test "History preview reads SHA-1 and SHA-256 root normal merge and range data from Git" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const cases = [_]struct { name: []const u8, format: commit_diff.ObjectFormat }{
        .{ .name = "sha1", .format = .sha1 },
        .{ .name = "sha256", .format = .sha256 },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const io = std.testing.io;
        const init_argv: []const []const u8 = switch (case.format) {
            .sha1 => &.{ "git", "init", "--object-format=sha1", "--initial-branch=main", "-q" },
            .sha256 => &.{ "git", "init", "--object-format=sha256", "--initial-branch=main", "-q" },
        };
        if (!try previewTestGitSucceeds(io, tmp.dir, init_argv)) {
            if (case.format == .sha256) continue;
            return error.GitCommandFailed;
        }
        try importPreviewHistory(io, tmp.dir);
        try previewRunTestGit(io, tmp.dir, &.{ "git", "tag", "root-light", "root-pin" });
        try previewRunTestGit(io, tmp.dir, &.{
            "git",       "-c", "user.name=Tagger", "-c",       "user.email=tagger@example.invalid",
            "tag",       "-a", "root-annotated",   "root-pin", "-m",
            "annotated",
        });
        const root_text = try previewTestGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "root-pin" });
        defer std.testing.allocator.free(root_text);
        const normal_text = try previewTestGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "normal-pin" });
        defer std.testing.allocator.free(normal_text);
        const side_text = try previewTestGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "side" });
        defer std.testing.allocator.free(side_text);
        const merge_text = try previewTestGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "merge-pin" });
        defer std.testing.allocator.free(merge_text);
        const root_oid = try commit_diff.ObjectId.parse(case.format, try previewTestLine(root_text));
        const normal_oid = try commit_diff.ObjectId.parse(case.format, try previewTestLine(normal_text));
        const side_oid = try commit_diff.ObjectId.parse(case.format, try previewTestLine(side_text));
        const merge_oid = try commit_diff.ObjectId.parse(case.format, try previewTestLine(merge_text));
        try previewRunTestGit(io, tmp.dir, &.{ "git", "update-ref", "-d", "refs/heads/normal-pin" });
        try previewRunTestGit(io, tmp.dir, &.{ "git", "update-ref", "refs/remotes/origin/root", root_oid.slice() });
        try previewRunTestGit(io, tmp.dir, &.{
            "git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/root",
        });

        var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
        defer environment.deinit();
        const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };

        const catalog_snapshot: history.Snapshot = .{
            .object_format = case.format,
            .head = merge_oid,
            .display = .detached,
        };
        const catalog_records = [_]history.Record{
            previewHistoryRecord(merge_oid, 2, .{ .available = normal_oid }),
            previewHistoryRecord(normal_oid, 1, .{ .available = root_oid }),
            previewHistoryRecord(root_oid, 0, .true_root),
        };
        const merge_request = history.resolveSelection(&catalog_snapshot, &catalog_records, null, 0).request;
        const normal_request = history.resolveSelection(&catalog_snapshot, &catalog_records, null, 1).request;
        const root_request = history.resolveSelection(&catalog_snapshot, &catalog_records, null, 2).request;
        const range_request = history.resolveSelection(&catalog_snapshot, &catalog_records, 0, 1).request;
        const root_range_request = history.resolveSelection(&catalog_snapshot, &catalog_records, 0, 2).request;

        if (case.format == .sha1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
            var allocation_failure = readPreview(failing.allocator(), io, context, root_request);
            defer allocation_failure.deinit(failing.allocator());
            switch (allocation_failure) {
                .rejected => |terminal| switch (terminal) {
                    .failed => |reason| try std.testing.expectEqual(FailureReason.allocation, reason),
                    else => return error.ExpectedAllocationFailure,
                },
                else => return error.ExpectedAllocationFailure,
            }
        }

        var root_commands: PreviewCommandCounts = .{};
        var root_result = readPreviewObserved(std.testing.allocator, io, context, root_request, &root_commands);
        defer root_result.deinit(std.testing.allocator);
        const root_verified = try expectVerifiedPreview(&root_result);
        const root_detail = switch (root_verified.payload.detail) {
            .ready => |detail| switch (detail) {
                .single => |single| single,
                else => return error.ExpectedSingleDetail,
            },
            else => return error.ExpectedReadyDetail,
        };
        try std.testing.expectEqualStrings("Root Author", root_detail.author.name);
        try std.testing.expectEqualStrings("root-author@example.invalid", root_detail.author.email);
        try std.testing.expectEqual(@as(i64, 100), root_detail.authored.unix_seconds);
        try std.testing.expectEqual(@as(i16, 330), root_detail.authored.offset_minutes);
        try std.testing.expectEqualStrings("Root Committer", root_detail.committer.name);
        try std.testing.expectEqual(@as(i64, 200), root_detail.committed.unix_seconds);
        try std.testing.expectEqual(@as(i16, -150), root_detail.committed.offset_minutes);
        try std.testing.expectEqualStrings("root subject\n\nroot body\n", root_detail.message);
        try std.testing.expectEqual(@as(usize, 2), root_detail.refs.tags.len);
        try std.testing.expectEqualStrings("root-annotated", root_detail.refs.tags[0]);
        try std.testing.expectEqualStrings("root-light", root_detail.refs.tags[1]);
        try std.testing.expectEqual(@as(usize, 1), root_detail.refs.remote_branches.len);
        try std.testing.expectEqualStrings("origin/root", root_detail.refs.remote_branches[0]);
        try expectSingleReadyFile(root_verified.payload.files, "root.txt", .added);
        try std.testing.expectEqual(@as(usize, 1), root_commands.selection_graph);
        try std.testing.expectEqual(@as(usize, 1), root_commands.root_probe);
        try std.testing.expectEqual(@as(usize, 0), root_commands.commit_metadata);

        var single_commands: PreviewCommandCounts = .{};
        var normal_result = readPreviewObserved(std.testing.allocator, io, context, normal_request, &single_commands);
        defer normal_result.deinit(std.testing.allocator);
        const normal_verified = try expectVerifiedPreview(&normal_result);
        try expectSingleReadyFile(normal_verified.payload.files, "normal.txt", .added);
        const normal_detail = switch (normal_verified.payload.detail) {
            .ready => |detail| switch (detail) {
                .single => |single| single,
                else => return error.ExpectedSingleDetail,
            },
            else => return error.ExpectedReadyDetail,
        };
        try std.testing.expectEqual(@as(usize, 0), normal_detail.refs.local_branches.len);
        try std.testing.expectEqual(@as(usize, 0), normal_detail.refs.tags.len);
        try std.testing.expectEqual(@as(usize, 0), normal_detail.refs.remote_branches.len);
        try std.testing.expectEqual(@as(usize, 1), single_commands.selection_graph);
        try std.testing.expectEqual(@as(usize, 0), single_commands.root_probe);
        try std.testing.expectEqual(@as(usize, 1), single_commands.commit_metadata);
        try std.testing.expectEqual(@as(usize, 1), single_commands.refs);
        try std.testing.expectEqual(@as(usize, 1), single_commands.raw);
        try std.testing.expectEqual(@as(usize, 1), single_commands.numstat);
        if (case.format == .sha1) {
            const normal_basis = normal_detail.summary.basis;
            try expectProjectionCaptureBoundary(io, context, normal_basis, .raw_z, raw_output_limit);
            try expectProjectionCaptureBoundary(io, context, normal_basis, .numstat_z, numstat_output_limit);
        }

        var merge_result = readPreview(std.testing.allocator, io, context, merge_request);
        defer merge_result.deinit(std.testing.allocator);
        const merge_verified = try expectVerifiedPreview(&merge_result);
        try expectSingleReadyFile(merge_verified.payload.files, "merge.txt", .added);
        try std.testing.expectEqual(@as(u32, 2), merge_verified.summary.single.parent_count);

        var range_commands: PreviewCommandCounts = .{};
        var range_result = readPreviewObserved(std.testing.allocator, io, context, range_request, &range_commands);
        defer range_result.deinit(std.testing.allocator);
        const range_verified = try expectVerifiedPreview(&range_result);
        const range_summary = range_verified.summary.range;
        try std.testing.expect(range_summary.oldest_oid.eql(&normal_oid));
        try std.testing.expect(range_summary.basis.before.commit.eql(&root_oid));
        switch (range_verified.payload.detail) {
            .ready => |detail| switch (detail) {
                .range => |actual| try std.testing.expect(actual.basis.eql(range_summary.basis)),
                else => return error.ExpectedRangeDetail,
            },
            else => return error.ExpectedReadyDetail,
        }
        const range_files = switch (range_verified.payload.files) {
            .ready => |files| files,
            else => return error.ExpectedReadyFiles,
        };
        try std.testing.expectEqual(@as(usize, 2), range_files.len);
        try std.testing.expectEqual(@as(usize, 1), range_commands.selection_graph);
        try std.testing.expectEqual(@as(usize, 0), range_commands.root_probe);
        try std.testing.expectEqual(@as(usize, 0), range_commands.commit_metadata);
        try std.testing.expectEqual(@as(usize, 0), range_commands.refs);
        try std.testing.expectEqual(@as(usize, 1), range_commands.raw);
        try std.testing.expectEqual(@as(usize, 1), range_commands.numstat);

        if (case.format == .sha1) {
            var nonroot_empty_tree = range_request;
            nonroot_empty_tree.basis.before = .empty_tree;
            var forged_counts: PreviewCommandCounts = .{};
            var forged_root = readPreviewObserved(std.testing.allocator, io, context, nonroot_empty_tree, &forged_counts);
            defer forged_root.deinit(std.testing.allocator);
            try expectRejectedSelection(forged_root, .malformed);
            try expectNoComponentCommands(forged_counts);

            var unrelated_before = range_request;
            unrelated_before.basis.before = .{ .commit = side_oid };
            forged_counts = .{};
            var forged_unrelated = readPreviewObserved(std.testing.allocator, io, context, unrelated_before, &forged_counts);
            defer forged_unrelated.deinit(std.testing.allocator);
            try expectRejectedSelection(forged_unrelated, .malformed);
            try expectNoComponentCommands(forged_counts);

            var over_limit = normal_request;
            over_limit.intent.single.index = history.catalog_limit;
            forged_counts = .{};
            var rejected_limit = readPreviewObserved(std.testing.allocator, io, context, over_limit, &forged_counts);
            defer rejected_limit.deinit(std.testing.allocator);
            try expectRejectedSelection(rejected_limit, .malformed);
            try std.testing.expectEqual(@as(usize, 0), forged_counts.selection_graph);

            forged_counts = .{};
            const graph_limit_admission = admitSelection(
                std.testing.allocator,
                io,
                context,
                range_request,
                1,
                &forged_counts,
            );
            switch (graph_limit_admission) {
                .rejected => |terminal| switch (terminal) {
                    .too_large => |stage| try std.testing.expectEqual(
                        SelectionTooLargeStage.selection_graph,
                        stage,
                    ),
                    else => return error.ExpectedSelectionGraphTooLarge,
                },
                .verified => |verified| {
                    if (verified.root_object) |object| std.testing.allocator.free(object);
                    return error.ExpectedSelectionGraphTooLarge;
                },
            }
            try expectNoComponentCommands(forged_counts);

            const source_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
            defer std.testing.allocator.free(source_path);
            const source_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{source_path});
            defer std.testing.allocator.free(source_url);
            try previewRunTestGit(io, tmp.dir, &.{
                "git", "clone", "-q", "--depth=2", "--single-branch", "--no-tags", source_url, "shallow",
            });
            var shallow = try tmp.dir.openDir(io, "shallow", .{});
            defer shallow.close(io);
            const shallow_context: git_command.DirectoryContext = .{ .cwd = shallow, .environment = &environment };
            var shallow_counts: PreviewCommandCounts = .{};
            var shallow_result = readPreviewObserved(
                std.testing.allocator,
                io,
                shallow_context,
                range_request,
                &shallow_counts,
            );
            defer shallow_result.deinit(std.testing.allocator);
            try expectRejectedSelection(shallow_result, .unavailable);
            try std.testing.expectEqual(@as(usize, 1), shallow_counts.selection_graph);
            try std.testing.expectEqual(@as(usize, 1), shallow_counts.root_probe);
            try expectNoComponentCommands(shallow_counts);
        }

        var root_range_commands: PreviewCommandCounts = .{};
        var root_range_result = readPreviewObserved(std.testing.allocator, io, context, root_range_request, &root_range_commands);
        defer root_range_result.deinit(std.testing.allocator);
        const root_range_verified = try expectVerifiedPreview(&root_range_result);
        try std.testing.expect(root_range_verified.summary.range.oldest_oid.eql(&root_oid));
        try std.testing.expect(root_range_verified.summary.range.basis.before == .empty_tree);
        try std.testing.expect(root_range_verified.payload.detail == .ready);
        try std.testing.expect(root_range_verified.payload.files == .ready);
        try std.testing.expectEqual(@as(usize, 1), root_range_commands.selection_graph);
        try std.testing.expectEqual(@as(usize, 1), root_range_commands.root_probe);
        try std.testing.expectEqual(@as(usize, 0), root_range_commands.commit_metadata);
        try std.testing.expectEqual(@as(usize, 0), root_range_commands.refs);
        try std.testing.expectEqual(@as(usize, 1), root_range_commands.raw);
        try std.testing.expectEqual(@as(usize, 1), root_range_commands.numstat);

        const missing_oid = switch (case.format) {
            .sha1 => try commit_diff.ObjectId.parse(.sha1, "ffffffffffffffffffffffffffffffffffffffff"),
            .sha256 => try commit_diff.ObjectId.parse(.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
        };
        var after_missing = readPreviewFromSummary(std.testing.allocator, io, context, .{ .single = .{
            .selected_oid = missing_oid,
            .parent_count = 0,
            .basis = .{ .object_format = case.format, .before = .empty_tree, .after = missing_oid },
        } });
        defer after_missing.deinit(std.testing.allocator);
        try expectUnavailablePayload(after_missing, .after_missing);
        var before_missing = readPreviewFromSummary(std.testing.allocator, io, context, .{ .single = .{
            .selected_oid = normal_oid,
            .parent_count = 1,
            .basis = .{ .object_format = case.format, .before = .{ .commit = missing_oid }, .after = normal_oid },
        } });
        defer before_missing.deinit(std.testing.allocator);
        try expectUnavailablePayload(before_missing, .before_missing);

        const tree_text = try previewTestGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "root-pin^{tree}" });
        defer std.testing.allocator.free(tree_text);
        const tree_oid = try commit_diff.ObjectId.parse(case.format, try previewTestLine(tree_text));
        if (case.format == .sha1) {
            const exact_commit_oid = try previewWriteSizedCommitObject(
                std.testing.allocator,
                io,
                context,
                case.format,
                tree_oid,
                commit_object_limit,
            );
            var exact_commit_payload = readPreviewFromSummary(std.testing.allocator, io, context, .{ .single = .{
                .selected_oid = exact_commit_oid,
                .parent_count = 0,
                .basis = .{ .object_format = case.format, .before = .empty_tree, .after = exact_commit_oid },
            } });
            defer exact_commit_payload.deinit(std.testing.allocator);
            switch (exact_commit_payload.detail) {
                .too_large => |stage| try std.testing.expectEqual(DetailTooLargeStage.message, stage),
                else => return error.ExpectedMessageTooLarge,
            }

            const oversized_commit_oid = try previewWriteSizedCommitObject(
                std.testing.allocator,
                io,
                context,
                case.format,
                tree_oid,
                commit_object_limit + 1,
            );
            var oversized_commit_payload = readPreviewFromSummary(std.testing.allocator, io, context, .{ .single = .{
                .selected_oid = oversized_commit_oid,
                .parent_count = 0,
                .basis = .{ .object_format = case.format, .before = .empty_tree, .after = oversized_commit_oid },
            } });
            defer oversized_commit_payload.deinit(std.testing.allocator);
            switch (oversized_commit_payload.detail) {
                .too_large => |stage| try std.testing.expectEqual(DetailTooLargeStage.commit_object, stage),
                else => return error.ExpectedCommitObjectTooLarge,
            }
        }
        var before_wrong_kind = readPreviewFromSummary(std.testing.allocator, io, context, .{ .single = .{
            .selected_oid = normal_oid,
            .parent_count = 1,
            .basis = .{ .object_format = case.format, .before = .{ .commit = tree_oid }, .after = normal_oid },
        } });
        defer before_wrong_kind.deinit(std.testing.allocator);
        try expectUnavailablePayload(before_wrong_kind, .before_wrong_kind);
        var after_wrong_kind = readPreviewFromSummary(std.testing.allocator, io, context, .{ .single = .{
            .selected_oid = tree_oid,
            .parent_count = 0,
            .basis = .{ .object_format = case.format, .before = .empty_tree, .after = tree_oid },
        } });
        defer after_wrong_kind.deinit(std.testing.allocator);
        try expectUnavailablePayload(after_wrong_kind, .after_wrong_kind);

        const drift_format: commit_diff.ObjectFormat = if (case.format == .sha1) .sha256 else .sha1;
        const drift_oid = switch (drift_format) {
            .sha1 => try commit_diff.ObjectId.parse(.sha1, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
            .sha256 => try commit_diff.ObjectId.parse(.sha256, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
        };
        var format_drift = readPreviewFromSummary(std.testing.allocator, io, context, .{ .single = .{
            .selected_oid = drift_oid,
            .parent_count = 0,
            .basis = .{ .object_format = drift_format, .before = .empty_tree, .after = drift_oid },
        } });
        defer format_drift.deinit(std.testing.allocator);
        try expectUnavailablePayload(format_drift, .repository_format_drift);
        _ = case.name;
    }
}

fn importPreviewHistory(io: std.Io, cwd: std.Io.Dir) !void {
    var stream: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stream.deinit();
    const writer = &stream.writer;
    try writer.writeAll("blob\nmark :1\n");
    try previewWriteFastImportData(writer, "root\n");
    try writer.writeAll(
        "commit refs/heads/main\nmark :2\n" ++
            "author Root Author <root-author@example.invalid> 100 +0530\n" ++
            "committer Root Committer <root-committer@example.invalid> 200 -0230\n",
    );
    try previewWriteFastImportData(writer, "root subject\n\nroot body\n");
    try writer.writeAll("M 100644 :1 root.txt\n\nblob\nmark :3\n");
    try previewWriteFastImportData(writer, "normal\n");
    try writer.writeAll(
        "commit refs/heads/main\nmark :4\n" ++
            "author Normal Author <normal-author@example.invalid> 300 +0000\n" ++
            "committer Normal Committer <normal-committer@example.invalid> 301 +0000\n",
    );
    try previewWriteFastImportData(writer, "normal\n");
    try writer.writeAll("from :2\nM 100644 :3 normal.txt\n\nblob\nmark :5\n");
    try previewWriteFastImportData(writer, "side\n");
    try writer.writeAll(
        "commit refs/heads/side\nmark :6\n" ++
            "author Side <side@example.invalid> 400 +0000\n" ++
            "committer Side <side@example.invalid> 400 +0000\n",
    );
    try previewWriteFastImportData(writer, "side\n");
    try writer.writeAll("from :2\nM 100644 :5 side.txt\n\nblob\nmark :7\n");
    try previewWriteFastImportData(writer, "merge\n");
    try writer.writeAll(
        "commit refs/heads/main\nmark :8\n" ++
            "author Merge <merge@example.invalid> 500 +0000\n" ++
            "committer Merge <merge@example.invalid> 500 +0000\n",
    );
    try previewWriteFastImportData(writer, "merge\n");
    try writer.writeAll(
        "from :4\nmerge :6\nM 100644 :7 merge.txt\n\n" ++
            "reset refs/heads/root-pin\nfrom :2\n\n" ++
            "reset refs/heads/normal-pin\nfrom :4\n\n" ++
            "reset refs/heads/merge-pin\nfrom :8\n\n",
    );

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    var result = try git_command.runWithStdin(std.testing.allocator, io, .{
        .cwd = cwd,
        .environment = &environment,
    }, .{
        .argv = &.{ "git", "fast-import", "--quiet" },
        .stdin = stream.written(),
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer result.deinit(std.testing.allocator);
    if (!termExited(result.term, 0)) return error.GitCommandFailed;
}

fn previewHistoryRecord(
    oid: commit_diff.ObjectId,
    parent_count: u16,
    first_parent: history.FirstParent,
) history.Record {
    return .{
        .oid = oid,
        .parent_count = parent_count,
        .first_parent = first_parent,
        .author = @constCast(""),
        .committer_unix = 0,
        .decorations = @constCast(""),
        .subject = @constCast(""),
    };
}

fn previewWriteFastImportData(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.print("data {d}\n", .{bytes.len});
    try writer.writeAll(bytes);
    try writer.writeByte('\n');
}

fn previewRunTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    if (!try previewTestGitSucceeds(io, cwd, argv)) return error.GitCommandFailed;
}

fn previewTestGitSucceeds(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !bool {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    return termExited(result.term, 0);
}

fn previewTestGitOutput(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    errdefer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    if (!termExited(result.term, 0)) return error.GitCommandFailed;
    std.testing.allocator.free(result.stderr);
    return result.stdout;
}

fn previewWriteSizedCommitObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: commit_diff.ObjectFormat,
    tree_oid: commit_diff.ObjectId,
    object_size: usize,
) !commit_diff.ObjectId {
    const header = try std.fmt.allocPrint(
        allocator,
        "tree {s}\nauthor Limit <limit@example.invalid> 1 +0000\ncommitter Limit <limit@example.invalid> 1 +0000\n\n",
        .{tree_oid.slice()},
    );
    defer allocator.free(header);
    if (header.len > object_size) return error.InvalidObjectSize;
    const object = try allocator.alloc(u8, object_size);
    defer allocator.free(object);
    @memcpy(object[0..header.len], header);
    @memset(object[header.len..], 'm');
    var result = try git_command.runWithStdin(allocator, io, context, .{
        .argv = &.{ "git", "hash-object", "-t", "commit", "-w", "--stdin" },
        .stdin = object,
        .stdout_limit = .limited(128),
        .stderr_limit = .limited(stderr_limit),
    });
    defer result.deinit(allocator);
    if (!termExited(result.term, 0)) return error.GitCommandFailed;
    return commit_diff.ObjectId.parse(format, try previewTestLine(result.stdout));
}

fn expectProjectionCaptureBoundary(
    io: std.Io,
    context: git_command.DirectoryContext,
    basis: commit_diff.Basis,
    projection: commit_diff.DiffProjection,
    production_limit: usize,
) !void {
    const full = try captureProjection(std.testing.allocator, io, context, basis, projection, production_limit, null);
    const output_len = switch (full) {
        .bytes => |bytes| blk: {
            defer std.testing.allocator.free(bytes);
            break :blk bytes.len;
        },
        else => return error.ExpectedProjectionBytes,
    };
    try std.testing.expect(output_len > 0);
    const exact = try captureProjection(std.testing.allocator, io, context, basis, projection, output_len, null);
    switch (exact) {
        .bytes => |bytes| std.testing.allocator.free(bytes),
        else => return error.ExpectedProjectionBytes,
    }
    const exceeded = try captureProjection(std.testing.allocator, io, context, basis, projection, output_len - 1, null);
    try std.testing.expect(exceeded == .too_large);
}

fn previewTestLine(bytes: []const u8) ![]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.ExpectedLine;
    const line = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfScalar(u8, line, '\n') != null) return error.ExpectedLine;
    return line;
}

fn expectSingleReadyFile(result: FilesResult, path: []const u8, status: FileStatus) !void {
    const files = switch (result) {
        .ready => |files| files,
        else => return error.ExpectedReadyFiles,
    };
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings(path, files[0].canonicalPath());
    try std.testing.expectEqual(status, files[0].status());
}

fn expectVerifiedPreview(result: *PreviewReadResult) !*VerifiedPreview {
    return switch (result.*) {
        .verified => |*verified| verified,
        .rejected => error.ExpectedVerifiedPreview,
    };
}

fn expectRejectedSelection(result: PreviewReadResult, expected: SelectionAdmissionTerminal) !void {
    switch (result) {
        .rejected => |actual| try std.testing.expectEqual(
            std.meta.activeTag(expected),
            std.meta.activeTag(actual),
        ),
        .verified => return error.ExpectedRejectedSelection,
    }
}

fn expectNoComponentCommands(counts: PreviewCommandCounts) !void {
    try std.testing.expectEqual(@as(usize, 0), counts.commit_metadata);
    try std.testing.expectEqual(@as(usize, 0), counts.refs);
    try std.testing.expectEqual(@as(usize, 0), counts.raw);
    try std.testing.expectEqual(@as(usize, 0), counts.numstat);
}

fn expectUnavailablePayload(payload: PreviewPayload, reason: UnavailableReason) !void {
    switch (payload.detail) {
        .unavailable => |actual| try std.testing.expectEqual(reason, actual),
        else => return error.ExpectedUnavailableDetail,
    }
    switch (payload.files) {
        .unavailable => |actual| try std.testing.expectEqual(reason, actual),
        else => return error.ExpectedUnavailableFiles,
    }
}

test "History preview owned model releases ready component payloads" {
    const before = try testOid("1111111111111111111111111111111111111111");
    const after = try testOid("2222222222222222222222222222222222222222");
    const summary: SingleSummary = .{
        .selected_oid = after,
        .parent_count = 1,
        .basis = .{ .object_format = .sha1, .before = .{ .commit = before }, .after = after },
    };

    var author = try testIdentity("Author", "author@example.invalid");
    errdefer author.deinit(std.testing.allocator);
    var committer = try testIdentity("Committer", "committer@example.invalid");
    errdefer committer.deinit(std.testing.allocator);
    var refs: TypedRefs = .{
        .local_branches = try testOwnedStrings(&.{"main"}),
        .tags = &.{},
        .remote_branches = &.{},
    };
    errdefer refs.deinit(std.testing.allocator);
    refs.tags = try testOwnedStrings(&.{"v1"});
    refs.remote_branches = try testOwnedStrings(&.{"origin/main"});
    const message = try std.testing.allocator.dupe(u8, "subject\n\nbody\n");
    errdefer std.testing.allocator.free(message);

    const changes = try std.testing.allocator.alloc(FileChange, 2);
    var initialized_changes: usize = 0;
    errdefer {
        for (changes[0..initialized_changes]) |*change| change.deinit(std.testing.allocator);
        std.testing.allocator.free(changes);
    }
    changes[0] = .{
        .kind = .{ .modified = try std.testing.allocator.dupe(u8, "src/main.zig") },
        .old_mode = 0o100644,
        .new_mode = 0o100644,
        .old_oid = before,
        .new_oid = after,
        .stats = .{ .text = .{ .added = 2, .removed = 1 } },
    };
    initialized_changes += 1;
    changes[1] = .{
        .kind = .{ .renamed = .{
            .similarity = 75,
            .old = try std.testing.allocator.dupe(u8, "old -> name"),
            .new = try std.testing.allocator.dupe(u8, "new\xffname"),
        } },
        .old_mode = 0o100644,
        .new_mode = 0o100644,
        .old_oid = before,
        .new_oid = after,
        .stats = .binary,
    };
    initialized_changes += 1;

    var payload: PreviewPayload = .{
        .detail = .{ .ready = .{ .single = .{
            .summary = summary,
            .author = author,
            .authored = try Timestamp.init(1, "+0900"),
            .committer = committer,
            .committed = try Timestamp.init(2, "-0230"),
            .refs = refs,
            .message = message,
        } } },
        .files = .{ .ready = changes },
    };
    payload.deinit(std.testing.allocator);
}

test "History preview terminals and range summaries own no hidden payload" {
    const before = try testOid("1111111111111111111111111111111111111111");
    const after = try testOid("2222222222222222222222222222222222222222");
    var payload: PreviewPayload = .{
        .detail = .{ .ready = .{ .range = .{
            .count = 2,
            .oldest_oid = before,
            .newest_oid = after,
            .basis = .{ .object_format = .sha1, .before = .empty_tree, .after = after },
        } } },
        .files = .{ .too_large = .file_list },
    };
    payload.deinit(std.testing.allocator);

    var failed: PreviewPayload = .{
        .detail = .{ .unavailable = .after_missing },
        .files = .{ .failed = .malformed_output },
    };
    failed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i16, 0), (try Timestamp.init(0, "-0000")).offset_minutes);
    try std.testing.expectError(error.InvalidTimezone, Timestamp.init(0, "UTC"));
    try std.testing.expectError(error.InvalidTimezone, Timestamp.init(0, "+1260"));
    try std.testing.expectError(error.InvalidTimezone, Timestamp.init(0, "+2400"));
}

test "History preview file changes sort by raw canonical path" {
    const oid = try testOid("1111111111111111111111111111111111111111");
    var changes = [_]FileChange{
        .{ .kind = .{ .modified = "a.zig" }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .mode_only },
        .{ .kind = .{ .renamed = .{ .similarity = 100, .old = "z-old", .new = "src/z.zig" } }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .binary },
        .{ .kind = .{ .added = "docs/readme.md" }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .{ .text = .{ .added = 1, .removed = 0 } } },
        .{ .kind = .{ .modified = "src/lib/root.zig" }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .submodule },
    };
    std.mem.sort(FileChange, &changes, {}, fileChangeLessThan);
    const expected = [_][]const u8{ "docs/readme.md", "src/lib/root.zig", "src/z.zig", "a.zig" };
    for (expected, changes) |want, change| {
        try std.testing.expectEqualStrings(want, change.canonicalPath());
    }
}

test "History preview file change kind derives every status path and cleanup" {
    const oid = try testOid("1111111111111111111111111111111111111111");
    var changes = [_]FileChange{
        .{ .kind = .{ .modified = try std.testing.allocator.dupe(u8, "modified") }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .mode_only },
        .{ .kind = .{ .added = try std.testing.allocator.dupe(u8, "added") }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .mode_only },
        .{ .kind = .{ .deleted = try std.testing.allocator.dupe(u8, "deleted") }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .mode_only },
        .{ .kind = .{ .renamed = .{
            .similarity = 87,
            .old = try std.testing.allocator.dupe(u8, "old"),
            .new = try std.testing.allocator.dupe(u8, "new"),
        } }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .mode_only },
        .{ .kind = .{ .type_changed = try std.testing.allocator.dupe(u8, "type-changed") }, .old_mode = 0, .new_mode = 0, .old_oid = oid, .new_oid = oid, .stats = .mode_only },
    };
    defer for (&changes) |*change| change.deinit(std.testing.allocator);

    const expected_statuses = [_]FileStatus{ .modified, .added, .deleted, .renamed, .type_changed };
    const expected_badges = [_][]const u8{ "M", "A", "D", "R", "T" };
    const expected_paths = [_][]const u8{ "modified", "added", "deleted", "new", "type-changed" };
    for (changes, expected_statuses, expected_badges, expected_paths) |change, status, badge, canonical_path| {
        try std.testing.expectEqual(status, change.status());
        try std.testing.expectEqualStrings(badge, change.statusBadge());
        try std.testing.expectEqualStrings(canonical_path, change.canonicalPath());
    }
    try std.testing.expect(changes[0].renameSimilarity() == null);
    try std.testing.expectEqual(@as(?u8, 87), changes[3].renameSimilarity());
    switch (changes[3].kind) {
        .renamed => |rename| {
            try std.testing.expectEqualStrings("old", rename.old);
            try std.testing.expectEqualStrings("new", rename.new);
        },
        else => return error.ExpectedRename,
    }
}
