//! Exact committed-diff Git object operations shared by History and Compare.
//!
//! Target resolution, ahead counting, and patch materialization are separate
//! operations with finite failure vocabularies.

const std = @import("std");
const builtin = @import("builtin");
const git_command = @import("command.zig");
const endpoint = @import("commit_diff/endpoint.zig");
const root_ref = @import("commit_diff/root_ref.zig");

/// Object-id width used by every OID in one target or basis.
pub const ObjectFormat = enum {
    sha1,
    sha256,

    pub fn oidHexLength(self: ObjectFormat) usize {
        return switch (self) {
            .sha1 => 40,
            .sha256 => 64,
        };
    }
};

/// Inline-owned canonical lowercase hexadecimal Git object ID.
pub const ObjectId = struct {
    bytes: [64]u8 = [_]u8{0} ** 64,
    len: u8 = 0,

    pub fn parse(format: ObjectFormat, text: []const u8) error{InvalidObjectId}!ObjectId {
        if (text.len != format.oidHexLength()) return error.InvalidObjectId;
        var result: ObjectId = .{};
        for (text, 0..) |byte, index| {
            if (!isLowerHex(byte)) return error.InvalidObjectId;
            result.bytes[index] = byte;
        }
        result.len = @intCast(text.len);
        return result;
    }

    pub fn slice(self: *const ObjectId) []const u8 {
        std.debug.assert(self.len <= self.bytes.len);
        return self.bytes[0..self.len];
    }

    pub fn short(self: *const ObjectId) []const u8 {
        return self.slice()[0..@min(@as(usize, self.len), 7)];
    }

    pub fn eql(self: *const ObjectId, other: *const ObjectId) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }

    pub fn validFor(self: *const ObjectId, format: ObjectFormat) bool {
        if (self.len != format.oidHexLength()) return false;
        for (self.slice()) |byte| if (!isLowerHex(byte)) return false;
        return true;
    }
};

/// Complete pinned authority for one committed comparison.
pub const Target = struct {
    object_format: ObjectFormat,
    base_oid: ObjectId,
    head_oid: ObjectId,
    diff_base_oid: ObjectId,

    pub fn validate(self: *const Target) error{InvalidTarget}!void {
        if (!self.base_oid.validFor(self.object_format) or
            !self.head_oid.validFor(self.object_format) or
            !self.diff_base_oid.validFor(self.object_format)) return error.InvalidTarget;
    }

    pub fn eql(self: *const Target, other: *const Target) bool {
        return self.object_format == other.object_format and
            self.base_oid.eql(&other.base_oid) and
            self.head_oid.eql(&other.head_oid) and
            self.diff_base_oid.eql(&other.diff_base_oid);
    }
};

fn isLowerHex(byte: u8) bool {
    return switch (byte) {
        '0'...'9', 'a'...'f' => true,
        else => false,
    };
}

/// Borrowed base and head expressions for target resolution.
pub const TargetInput = struct {
    base: []const u8,
    head: []const u8,
};

pub const TargetResolutionFailure = enum {
    invalid_repository,
    unsupported_object_format,
    base_unsupported_commitish,
    head_unsupported_commitish,
    base_unresolved,
    head_unresolved,
    base_ambiguous,
    head_ambiguous,
    base_non_commit_object,
    head_non_commit_object,
    base_object_unavailable,
    head_object_unavailable,
    no_merge_base,
    ambiguous_merge_base,
    target_graph_unavailable,
    git_command_failed,
};

pub const TargetResolutionResult = union(enum) {
    target: Target,
    failure: TargetResolutionFailure,
};

pub const AheadFailure = enum {
    ahead_graph_unavailable,
    ahead_git_command_failed,
};

pub const AheadResult = union(enum) {
    count: u64,
    failure: AheadFailure,
};

/// Exact endpoints for one direct committed diff.
pub const Basis = struct {
    pub const Before = union(enum) {
        commit: ObjectId,
        empty_tree,
    };

    object_format: ObjectFormat,
    before: Before,
    after: ObjectId,

    pub fn validate(self: Basis) error{InvalidBasis}!void {
        if (!self.after.validFor(self.object_format)) return error.InvalidBasis;
        switch (self.before) {
            .commit => |oid| if (!oid.validFor(self.object_format)) return error.InvalidBasis,
            .empty_tree => {},
        }
    }

    pub fn beforeOid(self: Basis) ObjectId {
        return switch (self.before) {
            .commit => |oid| oid,
            .empty_tree => canonicalEmptyTreeOid(self.object_format),
        };
    }

    pub fn eql(self: Basis, other: Basis) bool {
        if (self.object_format != other.object_format or !self.after.eql(&other.after)) return false;
        return switch (self.before) {
            .commit => |left| switch (other.before) {
                .commit => |right| left.eql(&right),
                .empty_tree => false,
            },
            .empty_tree => other.before == .empty_tree,
        };
    }
};

/// One explicit committed-diff policy shared by every projection.
pub const DiffPolicy = struct {
    rename_similarity_percent: u8,
    rename_candidate_limit: u32,
    detect_copies: bool,
    allow_external_diff: bool,
    use_textconv: bool,
};

pub const committed_diff_policy: DiffPolicy = .{
    .rename_similarity_percent = 50,
    .rename_candidate_limit = 1_000,
    .detect_copies = false,
    .allow_external_diff = false,
    .use_textconv = false,
};

pub const DiffProjection = enum {
    patch,
    raw_z,
    numstat_z,
};

/// Owned argv for one exact-basis projection. Dynamic arguments are owned so
/// no slice points into a returned struct or caller-local Basis copy.
pub const DiffCommand = struct {
    argv: []const []const u8,
    attr_source: []u8,
    rename_similarity: []u8,
    rename_limit: []u8,
    before_oid: []u8,
    after_oid: []u8,

    pub fn deinit(self: *DiffCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
        allocator.free(self.attr_source);
        allocator.free(self.rename_similarity);
        allocator.free(self.rename_limit);
        allocator.free(self.before_oid);
        allocator.free(self.after_oid);
        self.* = undefined;
    }
};

pub const BasisAdmissionFailure = enum {
    invalid_basis,
    repository_format_drift,
    before_missing,
    before_wrong_kind,
    after_missing,
    after_wrong_kind,
    git_command_failed,
};

pub const BasisAdmissionResult = union(enum) {
    admitted,
    failure: BasisAdmissionFailure,
};

pub const Materialization = struct {
    patch_bytes: []u8,

    pub fn deinit(self: *Materialization, allocator: std.mem.Allocator) void {
        allocator.free(self.patch_bytes);
        self.* = undefined;
    }
};

/// The existing finite materialization terminals.
pub const MaterializationFailure = enum {
    projection_too_large,
    projection_git_command_failed,
};

pub const MaterializationResult = union(enum) {
    materialization: Materialization,
    failure: MaterializationFailure,

    pub fn deinit(self: *MaterializationResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .materialization => |*materialization| materialization.deinit(allocator),
            .failure => {},
        }
        self.* = .{ .failure = .projection_git_command_failed };
    }
};

const max_patch_bytes: usize = 16 * 1024 * 1024;
const stderr_capture_bytes: usize = 8 * 1024;
const oid_record_slack: usize = 2;

const strict_prefix = [_][]const u8{
    "git",
    "--no-replace-objects",
    "--no-lazy-fetch",
    "--no-optional-locks",
};

const EndpointSide = enum { base, head };

const EndpointFailure = enum {
    unsupported_commitish,
    unresolved,
    ambiguous,
    non_commit_object,
    object_unavailable,
    git_command_failed,
};

const EndpointResult = union(enum) {
    oid: ObjectId,
    failure: EndpointFailure,
};

const CandidateSource = enum {
    object,
    named,
};

const Candidate = struct {
    oid: ObjectId,
    source: CandidateSource,
};

const CandidateSet = struct {
    items: [9]Candidate = undefined,
    len: usize = 0,

    fn append(self: *CandidateSet, candidate: Candidate) bool {
        if (self.len == self.items.len) return false;
        self.items[self.len] = candidate;
        self.len += 1;
        return true;
    }
};

const TargetResolutionTestHook = struct {
    context: *anyopaque,
    after_endpoints: *const fn (*anyopaque, std.Io, std.Io.Dir) anyerror!void,
};

/// Pin base, head, and their exact-one best merge base, then stop. No ahead,
/// diff, tree, or blob materialization occurs in this operation.
pub fn resolveTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    input: TargetInput,
) std.mem.Allocator.Error!TargetResolutionResult {
    return resolveTargetWithTestHook(allocator, io, context, input, null);
}

fn resolveTargetWithTestHook(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    input: TargetInput,
    test_hook: ?TargetResolutionTestHook,
) std.mem.Allocator.Error!TargetResolutionResult {
    std.debug.assert(builtin.is_test or test_hook == null);
    const parsed_base = endpoint.parse(input.base) catch
        return .{ .failure = .base_unsupported_commitish };
    const parsed_head = endpoint.parse(input.head) catch
        return .{ .failure = .head_unsupported_commitish };

    const format_result = try readObjectFormat(allocator, io, context);
    const format = switch (format_result) {
        .format => |value| value,
        .invalid_repository => return .{ .failure = .invalid_repository },
        .unsupported => return .{ .failure = .unsupported_object_format },
        .failed => return .{ .failure = .git_command_failed },
    };

    const base_result = try resolveEndpoint(allocator, io, context, format, parsed_base);
    const base_oid = switch (base_result) {
        .oid => |oid| oid,
        .failure => |failure| return .{ .failure = endpointFailure(.base, failure) },
    };
    const head_result = try resolveEndpoint(allocator, io, context, format, parsed_head);
    const head_oid = switch (head_result) {
        .oid => |oid| oid,
        .failure => |failure| return .{ .failure = endpointFailure(.head, failure) },
    };
    if (test_hook) |hook| hook.after_endpoints(hook.context, io, context.cwd) catch
        return .{ .failure = .git_command_failed };
    const merge_result = try resolveMergeBase(allocator, io, context, format, base_oid, head_oid);
    const diff_base_oid = switch (merge_result) {
        .oid => |oid| oid,
        .no_merge_base => return .{ .failure = .no_merge_base },
        .ambiguous => return .{ .failure = .ambiguous_merge_base },
        .graph_unavailable => return .{ .failure = .target_graph_unavailable },
        .failed => return .{ .failure = .git_command_failed },
    };
    const target: Target = .{
        .object_format = format,
        .base_oid = base_oid,
        .head_oid = head_oid,
        .diff_base_oid = diff_base_oid,
    };
    target.validate() catch return .{ .failure = .git_command_failed };
    return .{ .target = target };
}

/// Compute the ahead count from the already pinned target graph.
pub fn computeAhead(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: Target,
) std.mem.Allocator.Error!AheadResult {
    target.validate() catch return .{ .failure = .ahead_git_command_failed };
    const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{
        target.diff_base_oid.slice(),
        target.head_oid.slice(),
    });
    defer allocator.free(range);
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "rev-list",       "--count",        range,
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(32),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .{ .failure = .ahead_git_command_failed },
    };
    if (!termExited(completed.term, 0)) return .{ .failure = .ahead_graph_unavailable };
    const text = singleLfLine(completed.stdout) orelse return .{ .failure = .ahead_git_command_failed };
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return .{ .failure = .ahead_git_command_failed };
    var count: u64 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return .{ .failure = .ahead_git_command_failed };
        count = std.math.mul(u64, count, 10) catch return .{ .failure = .ahead_git_command_failed };
        count = std.math.add(u64, count, byte - '0') catch return .{ .failure = .ahead_git_command_failed };
    }
    return .{ .count = count };
}

/// Materialize one direct exact-endpoint committed patch. The repository
/// format and both endpoint object kinds are admitted before diff capture;
/// versioned attributes come from `basis.after`.
pub fn materializeBasis(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    basis: Basis,
) std.mem.Allocator.Error!MaterializationResult {
    return materializeBasisInternal(allocator, io, context, basis);
}

/// Materialize the target's checkout-independent committed patch. Versioned
/// attributes come from `target.head_oid`; worktree/index content is excluded.
pub fn materializeTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: Target,
) std.mem.Allocator.Error!MaterializationResult {
    target.validate() catch return .{ .failure = .projection_git_command_failed };
    const basis: Basis = .{
        .object_format = target.object_format,
        .before = .{ .commit = target.diff_base_oid },
        .after = target.head_oid,
    };
    return materializeBasisInternal(allocator, io, context, basis);
}

fn materializeBasisInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    basis: Basis,
) std.mem.Allocator.Error!MaterializationResult {
    const capture = try captureBasis(allocator, io, context, basis);
    return switch (capture) {
        .bytes => |bytes| .{ .materialization = .{ .patch_bytes = bytes } },
        .failure => |failure| .{ .failure = failure },
    };
}

const MaterializationCapture = union(enum) {
    bytes: []u8,
    failure: MaterializationFailure,
};

pub fn canonicalEmptyTreeOid(format: ObjectFormat) ObjectId {
    const text = switch (format) {
        .sha1 => "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
        .sha256 => "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321",
    };
    return ObjectId.parse(format, text) catch unreachable;
}

/// Build the exact command contract after admission. Projection-specific
/// flags are the only variation; strict execution, attribute source, rename,
/// copy, external-diff, and textconv semantics are shared.
pub fn buildDiffCommand(
    allocator: std.mem.Allocator,
    basis: Basis,
    projection: DiffProjection,
) (std.mem.Allocator.Error || error{InvalidBasis})!DiffCommand {
    try basis.validate();
    const before = basis.beforeOid();
    const attr_source = try std.fmt.allocPrint(allocator, "--attr-source={s}", .{basis.after.slice()});
    errdefer allocator.free(attr_source);
    const rename_similarity = try std.fmt.allocPrint(allocator, "--find-renames={d}%", .{committed_diff_policy.rename_similarity_percent});
    errdefer allocator.free(rename_similarity);
    const rename_limit = try std.fmt.allocPrint(allocator, "-l{d}", .{committed_diff_policy.rename_candidate_limit});
    errdefer allocator.free(rename_limit);
    const before_oid = try allocator.dupe(u8, before.slice());
    errdefer allocator.free(before_oid);
    const after_oid = try allocator.dupe(u8, basis.after.slice());
    errdefer allocator.free(after_oid);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        strict_prefix[0],
        strict_prefix[1],
        strict_prefix[2],
        strict_prefix[3],
        attr_source,
        "diff",
        "--no-color",
    });
    if (!committed_diff_policy.allow_external_diff) try argv.append(allocator, "--no-ext-diff");
    if (!committed_diff_policy.use_textconv) try argv.append(allocator, "--no-textconv");
    try argv.appendSlice(allocator, &.{ "--no-renames", rename_similarity, rename_limit });
    if (committed_diff_policy.detect_copies) try argv.append(allocator, "--find-copies");
    switch (projection) {
        .patch => try argv.appendSlice(allocator, &.{ "--src-prefix=a/", "--dst-prefix=b/" }),
        .raw_z => try argv.appendSlice(allocator, &.{ "--raw", "--no-abbrev", "-z" }),
        .numstat_z => try argv.appendSlice(allocator, &.{ "--numstat", "-z" }),
    }
    try argv.appendSlice(allocator, &.{ before_oid, after_oid });

    return .{
        .argv = try argv.toOwnedSlice(allocator),
        .attr_source = attr_source,
        .rename_similarity = rename_similarity,
        .rename_limit = rename_limit,
        .before_oid = before_oid,
        .after_oid = after_oid,
    };
}

pub fn admitBasis(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    basis: Basis,
) std.mem.Allocator.Error!BasisAdmissionResult {
    basis.validate() catch return .{ .failure = .invalid_basis };
    const format_result = try readObjectFormat(allocator, io, context);
    const repository_format = switch (format_result) {
        .format => |value| value,
        .unsupported => return .{ .failure = .repository_format_drift },
        .invalid_repository, .failed => return .{ .failure = .git_command_failed },
    };
    if (repository_format != basis.object_format) return .{ .failure = .repository_format_drift };

    const before_oid = basis.beforeOid();
    const stdin = try std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{
        before_oid.slice(),
        basis.after.slice(),
    });
    defer allocator.free(stdin);
    const argv = [_][]const u8{
        strict_prefix[0],
        strict_prefix[1],
        strict_prefix[2],
        strict_prefix[3],
        "cat-file",
        "--batch-check=%(objectname) %(objecttype)",
    };
    const max_record_bytes = ObjectFormat.sha256.oidHexLength() + " missing\n".len;
    var result = try git_command.runWithStdinBounded(allocator, io, context, .{
        .argv = &argv,
        .stdin = stdin,
        .stdout_limit = .limited(2 * max_record_bytes),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .{ .failure = .git_command_failed },
    };
    if (!termExited(completed.term, 0)) return .{ .failure = .git_command_failed };
    return classifyBasisObjectRecords(basis, before_oid, completed.stdout);
}

fn classifyBasisObjectRecords(
    basis: Basis,
    before_oid: ObjectId,
    stdout: []const u8,
) BasisAdmissionResult {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    const expected_oids = [_]*const ObjectId{ &before_oid, &basis.after };
    const before_kind: []const u8 = switch (basis.before) {
        .commit => "commit",
        .empty_tree => "tree",
    };
    const expected_kinds = [_][]const u8{ before_kind, "commit" };
    const missing_failures = [_]BasisAdmissionFailure{ .before_missing, .after_missing };
    const wrong_kind_failures = [_]BasisAdmissionFailure{ .before_wrong_kind, .after_wrong_kind };
    for (expected_oids, expected_kinds, missing_failures, wrong_kind_failures) |oid, kind, missing, wrong_kind| {
        const line = lines.next() orelse return .{ .failure = .git_command_failed };
        if (line.len <= oid.slice().len or
            !std.mem.eql(u8, line[0..oid.slice().len], oid.slice()) or
            line[oid.slice().len] != ' ') return .{ .failure = .git_command_failed };
        const actual = line[oid.slice().len + 1 ..];
        if (std.mem.eql(u8, actual, "missing")) return .{ .failure = missing };
        if (!std.mem.eql(u8, actual, kind)) return .{ .failure = wrong_kind };
    }
    const terminal = lines.next() orelse return .{ .failure = .git_command_failed };
    if (terminal.len != 0 or lines.next() != null) return .{ .failure = .git_command_failed };
    return .admitted;
}

fn captureBasis(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    basis: Basis,
) std.mem.Allocator.Error!MaterializationCapture {
    if (try admitBasis(allocator, io, context, basis) != .admitted)
        return .{ .failure = .projection_git_command_failed };
    var command = buildDiffCommand(allocator, basis, .patch) catch |err| switch (err) {
        error.InvalidBasis => return .{ .failure = .projection_git_command_failed },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer command.deinit(allocator);
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = command.argv,
        .stdout_limit = .limited(max_patch_bytes),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    switch (result) {
        .stdout_limit_exceeded => return .{ .failure = .projection_too_large },
        .stderr_limit_exceeded => return .{ .failure = .projection_git_command_failed },
        .failed => |*failure| {
            failure.deinit(allocator);
            return .{ .failure = .projection_git_command_failed };
        },
        .completed => |completed| {
            if (!termExited(completed.term, 0)) {
                completed.deinit(allocator);
                return .{ .failure = .projection_git_command_failed };
            }
            allocator.free(completed.stderr);
            return .{ .bytes = completed.stdout };
        },
    }
}
const ObjectFormatResult = union(enum) {
    format: ObjectFormat,
    invalid_repository,
    unsupported,
    failed,
};

fn readObjectFormat(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) std.mem.Allocator.Error!ObjectFormatResult {
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1],       strict_prefix[2], strict_prefix[3],
        "rev-parse",      "--show-object-format",
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(16),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    if (!termExited(completed.term, 0)) {
        return if (try strictPrefixSupported(allocator, io, context)) .invalid_repository else .failed;
    }
    const text = singleLfLine(completed.stdout) orelse return .failed;
    if (std.mem.eql(u8, text, "sha1")) return .{ .format = .sha1 };
    if (std.mem.eql(u8, text, "sha256")) return .{ .format = .sha256 };
    return .unsupported;
}

fn strictPrefixSupported(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
) std.mem.Allocator.Error!bool {
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3], "--version",
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    return switch (result) {
        .completed => |value| termExited(value.term, 0),
        else => false,
    };
}

fn resolveEndpoint(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    parsed: endpoint.Parsed,
) std.mem.Allocator.Error!EndpointResult {
    var candidates: CandidateSet = .{};
    if (parsed.baseIsHex() and parsed.base.len >= 4 and parsed.base.len <= format.oidHexLength()) {
        switch (try probeObjectCandidates(allocator, io, context, format, parsed.base, &candidates)) {
            .ok => {},
            .ambiguous => return .{ .failure = .ambiguous },
            .unresolved, .failed => return .{ .failure = .git_command_failed },
        }
    }

    const ref_validity = try validateRefAtom(allocator, io, context, parsed.base);
    switch (ref_validity) {
        .failed => return .{ .failure = .git_command_failed },
        .invalid => {},
        .valid_one_level => {
            switch (try probeRootCandidate(allocator, io, context, format, parsed.base, &candidates)) {
                .ok => {},
                .ambiguous => return .{ .failure = .ambiguous },
                .unresolved => return .{ .failure = .unresolved },
                .failed => return .{ .failure = .git_command_failed },
            }
        },
        .valid_slash => {},
    }
    if (ref_validity != .invalid) {
        switch (try probeNamespaceCandidates(allocator, io, context, format, parsed.base, &candidates)) {
            .ok => {},
            .ambiguous => return .{ .failure = .ambiguous },
            .unresolved => return .{ .failure = .unresolved },
            .failed => return .{ .failure = .git_command_failed },
        }
    }

    if (candidates.len == 0) return .{ .failure = .unresolved };
    if (candidates.len != 1) return .{ .failure = .ambiguous };
    const selected = candidates.items[0];
    if (selected.source == .named and parsed.suffix_text.len != 0) {
        switch (try batchCheck(allocator, io, context, format, selected.oid.slice())) {
            .missing => return .{ .failure = .object_unavailable },
            .failed => return .{ .failure = .git_command_failed },
            .object => {},
        }
    }
    const expression = try std.fmt.allocPrint(allocator, "{s}{s}", .{ selected.oid.slice(), parsed.suffix_text });
    defer allocator.free(expression);
    return validateCommitExpression(allocator, io, context, format, expression, selected.source, parsed.suffix_text.len == 0);
}

const ProbeStatus = enum { ok, ambiguous, unresolved, failed };

fn probeObjectCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    base: []const u8,
    candidates: *CandidateSet,
) std.mem.Allocator.Error!ProbeStatus {
    const option = try std.fmt.allocPrint(allocator, "--disambiguate={s}", .{base});
    defer allocator.free(option);
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "rev-parse",      option,
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited((format.oidHexLength() + 1) * 2),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .stdout_limit_exceeded => return .ambiguous,
        .stderr_limit_exceeded, .failed => return .failed,
        .completed => |value| value,
    };
    if (!termExited(completed.term, 0)) return .failed;
    var records: [2]ObjectId = undefined;
    const count = parseOidRecords(format, completed.stdout, &records) orelse return .failed;
    if (count > 1) return .ambiguous;
    if (count == 1 and !candidates.append(.{ .oid = records[0], .source = .object })) return .ambiguous;
    return .ok;
}

const RefValidity = enum { invalid, valid_one_level, valid_slash, failed };

fn validateRefAtom(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    atom: []const u8,
) std.mem.Allocator.Error!RefValidity {
    const one_level = std.mem.indexOfScalar(u8, atom, '/') == null;
    const argv_one = [_][]const u8{
        strict_prefix[0],   strict_prefix[1],   strict_prefix[2], strict_prefix[3],
        "check-ref-format", "--allow-onelevel", atom,
    };
    const argv_slash = [_][]const u8{
        strict_prefix[0],   strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "check-ref-format", atom,
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = if (one_level) &argv_one else &argv_slash,
        .stdout_limit = .limited(0),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    return switch (completed.term) {
        .exited => |code| switch (code) {
            0 => if (one_level) .valid_one_level else .valid_slash,
            1 => .invalid,
            else => .failed,
        },
        else => .failed,
    };
}

fn probeRootCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    atom: []const u8,
    candidates: *CandidateSet,
) std.mem.Allocator.Error!ProbeStatus {
    std.debug.assert(std.mem.indexOfScalar(u8, atom, '/') == null);
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1],         strict_prefix[2], strict_prefix[3],
        "rev-parse",      "--path-format=absolute", "--git-path",     atom,
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited(endpoint.max_input_bytes + 1),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    if (!termExited(completed.term, 0)) return .failed;
    const path = singleLfLine(completed.stdout) orelse return .failed;
    var probe = try root_ref.probe(allocator, io, path);
    defer probe.deinit(allocator);
    switch (probe) {
        .absent => return .ok,
        .ambiguous => return .ambiguous,
        .failed => return .failed,
        .candidates => |*list| {
            if (list.len != 1) return .ambiguous;
            switch (list.items[0]) {
                .oid => |text| {
                    const oid = ObjectId.parse(format, text) catch return .failed;
                    if (!candidates.append(.{ .oid = oid, .source = .named })) return .ambiguous;
                },
                .symbolic_ref => |full_ref| {
                    switch (try validateRefAtom(allocator, io, context, full_ref)) {
                        .valid_slash => {},
                        .invalid, .valid_one_level, .failed => return .failed,
                    }
                    const ref_result = try probeFullRef(allocator, io, context, format, full_ref);
                    switch (ref_result) {
                        .absent, .race_unresolved => return .unresolved,
                        .failed => return .failed,
                        .oid => |oid| if (!candidates.append(.{ .oid = oid, .source = .named })) return .ambiguous,
                    }
                },
            }
        },
    }
    return .ok;
}

fn probeNamespaceCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    atom: []const u8,
    candidates: *CandidateSet,
) std.mem.Allocator.Error!ProbeStatus {
    if (std.mem.startsWith(u8, atom, "refs/")) {
        return appendRefCandidate(allocator, io, context, format, atom, candidates);
    }
    var refs: [5][]u8 = undefined;
    var refs_len: usize = 0;
    defer for (refs[0..refs_len]) |value| allocator.free(value);
    refs[refs_len] = try std.fmt.allocPrint(allocator, "refs/{s}", .{atom});
    refs_len += 1;
    refs[refs_len] = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{atom});
    refs_len += 1;
    refs[refs_len] = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{atom});
    refs_len += 1;
    refs[refs_len] = try std.fmt.allocPrint(allocator, "refs/remotes/{s}", .{atom});
    refs_len += 1;
    refs[refs_len] = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/HEAD", .{atom});
    refs_len += 1;
    for (refs[0..refs_len]) |full_ref| {
        const status = try appendRefCandidate(allocator, io, context, format, full_ref, candidates);
        if (status != .ok) return status;
    }
    return .ok;
}

fn appendRefCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    full_ref: []const u8,
    candidates: *CandidateSet,
) std.mem.Allocator.Error!ProbeStatus {
    return switch (try probeFullRef(allocator, io, context, format, full_ref)) {
        .absent => .ok,
        .race_unresolved => .unresolved,
        .failed => .failed,
        .oid => |oid| if (candidates.append(.{ .oid = oid, .source = .named })) .ok else .ambiguous,
    };
}

const RefProbeResult = union(enum) {
    absent,
    race_unresolved,
    oid: ObjectId,
    failed,
};

fn probeFullRef(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    full_ref: []const u8,
) std.mem.Allocator.Error!RefProbeResult {
    const exists_argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "show-ref",       "--exists",       full_ref,
    };
    var exists = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &exists_argv,
        .stdout_limit = .limited(0),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer exists.deinit(allocator);
    const exists_completed = switch (exists) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    switch (exists_completed.term) {
        .exited => |code| switch (code) {
            0 => {},
            2 => return .absent,
            else => return .failed,
        },
        else => return .failed,
    }

    const hash_argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "show-ref",       "--verify",       "--hash",         full_ref,
    };
    var hash = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &hash_argv,
        .stdout_limit = .limited(format.oidHexLength() + oid_record_slack),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer hash.deinit(allocator);
    const hash_completed = switch (hash) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    if (!termExited(hash_completed.term, 0)) return .race_unresolved;
    const oid = parseSingleOid(format, hash_completed.stdout) orelse return .failed;
    return .{ .oid = oid };
}

fn validateCommitExpression(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    expression: []const u8,
    source: CandidateSource,
    no_suffix: bool,
) std.mem.Allocator.Error!EndpointResult {
    const checked = try batchCheck(allocator, io, context, format, expression);
    switch (checked) {
        .missing => return .{ .failure = if (source == .named and no_suffix) .object_unavailable else .unresolved },
        .failed => return .{ .failure = .git_command_failed },
        .object => |object| switch (object.kind) {
            .commit => return .{ .oid = object.oid },
            .tag => {
                const peel = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{object.oid.slice()});
                defer allocator.free(peel);
                return switch (try batchCheck(allocator, io, context, format, peel)) {
                    .object => |peeled| if (peeled.kind == .commit)
                        .{ .oid = peeled.oid }
                    else
                        .{ .failure = .non_commit_object },
                    .missing => .{ .failure = .object_unavailable },
                    .failed => .{ .failure = .git_command_failed },
                };
            },
            .blob, .other => return .{ .failure = .non_commit_object },
        },
    }
}

const BatchKind = enum { commit, tag, blob, other };
const BatchObject = struct { oid: ObjectId, kind: BatchKind };
const BatchResult = union(enum) { object: BatchObject, missing, failed };

fn batchCheck(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    expression: []const u8,
) std.mem.Allocator.Error!BatchResult {
    const stdin = try std.fmt.allocPrint(allocator, "{s}\n", .{expression});
    defer allocator.free(stdin);
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "cat-file",       "--batch-check",
    };
    var result = try git_command.runWithStdinBounded(allocator, io, context, .{
        .argv = &argv,
        .stdin = stdin,
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .stdout_limit_exceeded, .stderr_limit_exceeded, .failed => return .failed,
    };
    if (!termExited(completed.term, 0)) return .failed;
    const line = singleLfLine(completed.stdout) orelse return .failed;
    if (std.mem.endsWith(u8, line, " missing")) return .missing;
    var fields = std.mem.splitScalar(u8, line, ' ');
    const oid_text = fields.next() orelse return .failed;
    const type_text = fields.next() orelse return .failed;
    const size_text = fields.next() orelse return .failed;
    if (fields.next() != null or size_text.len == 0) return .failed;
    for (size_text) |byte| if (!std.ascii.isDigit(byte)) return .failed;
    const oid = ObjectId.parse(format, oid_text) catch return .failed;
    const kind: BatchKind = if (std.mem.eql(u8, type_text, "commit"))
        .commit
    else if (std.mem.eql(u8, type_text, "tag"))
        .tag
    else if (std.mem.eql(u8, type_text, "blob"))
        .blob
    else
        .other;
    return .{ .object = .{ .oid = oid, .kind = kind } };
}

const MergeBaseResult = union(enum) { oid: ObjectId, no_merge_base, ambiguous, graph_unavailable, failed };

fn resolveMergeBase(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: ObjectFormat,
    base_oid: ObjectId,
    head_oid: ObjectId,
) std.mem.Allocator.Error!MergeBaseResult {
    const argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "merge-base",     "--all",          base_oid.slice(), head_oid.slice(),
    };
    var result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &argv,
        .stdout_limit = .limited((format.oidHexLength() + 1) * 2),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer result.deinit(allocator);
    const completed = switch (result) {
        .stdout_limit_exceeded => return .ambiguous,
        .stderr_limit_exceeded, .failed => return .failed,
        .completed => |value| value,
    };
    var records: [2]ObjectId = undefined;
    const count = parseOidRecords(format, completed.stdout, &records) orelse return .failed;
    return switch (completed.term) {
        .exited => |code| if (code == 0)
            if (count == 1) .{ .oid = records[0] } else if (count > 1) .ambiguous else .failed
        else if (code == 1 and count == 0)
            .no_merge_base
        else
            .graph_unavailable,
        else => .failed,
    };
}

fn endpointFailure(side: EndpointSide, failure: EndpointFailure) TargetResolutionFailure {
    return switch (side) {
        .base => switch (failure) {
            .unsupported_commitish => .base_unsupported_commitish,
            .unresolved => .base_unresolved,
            .ambiguous => .base_ambiguous,
            .non_commit_object => .base_non_commit_object,
            .object_unavailable => .base_object_unavailable,
            .git_command_failed => .git_command_failed,
        },
        .head => switch (failure) {
            .unsupported_commitish => .head_unsupported_commitish,
            .unresolved => .head_unresolved,
            .ambiguous => .head_ambiguous,
            .non_commit_object => .head_non_commit_object,
            .object_unavailable => .head_object_unavailable,
            .git_command_failed => .git_command_failed,
        },
    };
}

fn parseSingleOid(format: ObjectFormat, bytes: []const u8) ?ObjectId {
    const line = singleLfLine(bytes) orelse return null;
    return ObjectId.parse(format, line) catch null;
}

fn parseOidRecords(format: ObjectFormat, bytes: []const u8, output: *[2]ObjectId) ?usize {
    if (bytes.len == 0) return 0;
    if (bytes[bytes.len - 1] != '\n' or std.mem.indexOfScalar(u8, bytes, '\r') != null) return null;
    var records = std.mem.splitScalar(u8, bytes[0 .. bytes.len - 1], '\n');
    var count: usize = 0;
    while (records.next()) |record| {
        if (record.len == 0 or count == output.len) return null;
        output[count] = ObjectId.parse(format, record) catch return null;
        count += 1;
    }
    return count;
}

fn singleLfLine(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return null;
    const line = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfScalar(u8, line, '\n') != null or std.mem.indexOfScalar(u8, line, '\r') != null) return null;
    return line;
}

fn termExited(term: std.process.Child.Term, expected: u8) bool {
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
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, result);
    if (!termExited(result.term, 0)) return error.GitCommandFailed;
}

fn testGitOutput(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    errdefer freeRunResult(std.testing.allocator, result);
    if (!termExited(result.term, 0)) {
        freeRunResult(std.testing.allocator, result);
        return error.GitCommandFailed;
    }
    std.testing.allocator.free(result.stderr);
    return result.stdout;
}

fn testDiffProjectionOutput(io: std.Io, cwd: std.Io.Dir, basis: Basis, projection: DiffProjection) ![]u8 {
    var command = try buildDiffCommand(std.testing.allocator, basis, projection);
    defer command.deinit(std.testing.allocator);
    return testGitOutput(io, cwd, command.argv);
}

fn expectHistoryPreviewRenamePolicyOutput(io: std.Io, cwd: std.Io.Dir, basis: Basis) !void {
    const patch = try testDiffProjectionOutput(io, cwd, basis, .patch);
    defer std.testing.allocator.free(patch);
    try std.testing.expect(std.mem.indexOf(u8, patch, "similarity index 100%\nrename from rename-old.txt\nrename to rename-new.txt\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "diff --git a/copy-new.txt b/copy-new.txt\nnew file mode ") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "copy from ") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "copy to ") == null);

    const raw = try testDiffProjectionOutput(io, cwd, basis, .raw_z);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, " R100\x00rename-old.txt\x00rename-new.txt\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, " A\x00copy-new.txt\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, " C") == null);

    const numstat = try testDiffProjectionOutput(io, cwd, basis, .numstat_z);
    defer std.testing.allocator.free(numstat);
    try std.testing.expect(std.mem.indexOf(u8, numstat, "0\t0\t\x00rename-old.txt\x00rename-new.txt\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, numstat, "1\t0\tcopy-new.txt\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, numstat, "\x00copy-source.txt\x00copy-new.txt\x00") == null);
}

fn testOutputLine(bytes: []const u8) ![]const u8 {
    return singleLfLine(bytes) orelse error.ExpectedSingleLine;
}

fn expectTarget(result: TargetResolutionResult) !Target {
    return switch (result) {
        .target => |target| target,
        .failure => return error.ExpectedTarget,
    };
}

fn expectAdmitted(result: BasisAdmissionResult) !void {
    switch (result) {
        .admitted => {},
        .failure => return error.ExpectedAdmittedBasis,
    }
}

fn expectAdmissionFailure(result: BasisAdmissionResult, expected: BasisAdmissionFailure) !void {
    switch (result) {
        .admitted => return error.ExpectedBasisAdmissionFailure,
        .failure => |actual| try std.testing.expectEqual(expected, actual),
    }
}

fn expectCommandPrefix(command: DiffCommand, basis: Basis) !void {
    const expected = [_][]const u8{
        "git",
        "--no-replace-objects",
        "--no-lazy-fetch",
        "--no-optional-locks",
        command.attr_source,
        "diff",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--no-renames",
        command.rename_similarity,
        command.rename_limit,
    };
    try std.testing.expect(command.argv.len >= expected.len + 2);
    for (expected, command.argv[0..expected.len]) |want, actual| {
        try std.testing.expectEqualStrings(want, actual);
    }
    try std.testing.expectEqualStrings("--attr-source=2222222222222222222222222222222222222222", command.attr_source);
    try std.testing.expectEqualStrings("--find-renames=50%", command.rename_similarity);
    try std.testing.expectEqualStrings("-l1000", command.rename_limit);
    try std.testing.expectEqualStrings(basis.beforeOid().slice(), command.argv[command.argv.len - 2]);
    try std.testing.expectEqualStrings(basis.after.slice(), command.argv[command.argv.len - 1]);
}

fn testRawPatch(io: std.Io, cwd: std.Io.Dir, target: Target) ![]u8 {
    const basis: Basis = .{
        .object_format = target.object_format,
        .before = .{ .commit = target.diff_base_oid },
        .after = target.head_oid,
    };
    var command = try buildDiffCommand(std.testing.allocator, basis, .patch);
    defer command.deinit(std.testing.allocator);
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = command.argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(max_patch_bytes + 2 * 1024 * 1024),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    errdefer freeRunResult(std.testing.allocator, result);
    if (!termExited(result.term, 0)) {
        freeRunResult(std.testing.allocator, result);
        return error.GitCommandFailed;
    }
    std.testing.allocator.free(result.stderr);
    return result.stdout;
}

fn inventoryLineLessThan(_: void, left: []u8, right: []u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn collectObjectInventory(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    prefix: []const u8,
    lines: *std.ArrayList([]u8),
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const relative = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(relative);
        switch (entry.kind) {
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                try collectObjectInventory(allocator, io, child, relative, lines);
            },
            .file => {
                const bytes = try dir.readFileAlloc(io, entry.name, allocator, .limited(64 * 1024 * 1024));
                defer allocator.free(bytes);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
                const hex = std.fmt.bytesToHex(digest, .lower);
                const line = try std.fmt.allocPrint(allocator, "{s}\tfile\t{d}\t{s}\n", .{ relative, bytes.len, &hex });
                errdefer allocator.free(line);
                try lines.append(allocator, line);
            },
            else => {
                const line = try std.fmt.allocPrint(allocator, "{s}\t{s}\n", .{ relative, @tagName(entry.kind) });
                errdefer allocator.free(line);
                try lines.append(allocator, line);
            },
        }
    }
}

fn objectInventory(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) ![]u8 {
    var objects = try cwd.openDir(io, ".git/objects", .{ .iterate = true });
    defer objects.close(io);
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    try collectObjectInventory(allocator, io, objects, "", &lines);
    std.mem.sort([]u8, lines.items, {}, inventoryLineLessThan);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (lines.items) |line| try result.appendSlice(allocator, line);
    return result.toOwnedSlice(allocator);
}

const RefMovementTestContext = struct {
    base_ref: []const u8,
    new_base_oid: []const u8,
    head_ref: []const u8,
    new_head_oid: []const u8,

    fn move(context_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) anyerror!void {
        const context: *@This() = @ptrCast(@alignCast(context_ptr));
        try runTestGit(io, cwd, &.{ "git", "update-ref", context.base_ref, context.new_base_oid });
        try runTestGit(io, cwd, &.{ "git", "update-ref", context.head_ref, context.new_head_oid });
    }
};

test "object IDs and targets enforce format width lowercase and four-field equality" {
    const sha1 = try ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    const sha256 = try ObjectId.parse(.sha256, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    try std.testing.expectEqualStrings("0123456", sha1.short());
    try std.testing.expect(sha256.validFor(.sha256));
    try std.testing.expectError(error.InvalidObjectId, ObjectId.parse(.sha1, "0123456789ABCDEF0123456789abcdef01234567"));

    const target: Target = .{
        .object_format = .sha1,
        .base_oid = sha1,
        .head_oid = sha1,
        .diff_base_oid = sha1,
    };
    try target.validate();
    try std.testing.expect(target.eql(&target));
    var invalid = target;
    invalid.head_oid.bytes[0] = 'A';
    try std.testing.expectError(error.InvalidTarget, invalid.validate());
    try std.testing.expect(!target.eql(&invalid));
}

test "History preview diff projections share one exact committed policy" {
    const before = try ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const after = try ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const basis: Basis = .{
        .object_format = .sha1,
        .before = .{ .commit = before },
        .after = after,
    };
    try std.testing.expectEqual(@as(u8, 50), committed_diff_policy.rename_similarity_percent);
    try std.testing.expectEqual(@as(u32, 1_000), committed_diff_policy.rename_candidate_limit);
    try std.testing.expect(!committed_diff_policy.detect_copies);
    try std.testing.expect(!committed_diff_policy.allow_external_diff);
    try std.testing.expect(!committed_diff_policy.use_textconv);

    var patch = try buildDiffCommand(std.testing.allocator, basis, .patch);
    defer patch.deinit(std.testing.allocator);
    try expectCommandPrefix(patch, basis);
    try std.testing.expectEqualSlices([]const u8, &.{ "--src-prefix=a/", "--dst-prefix=b/" }, patch.argv[12 .. patch.argv.len - 2]);

    var raw = try buildDiffCommand(std.testing.allocator, basis, .raw_z);
    defer raw.deinit(std.testing.allocator);
    try expectCommandPrefix(raw, basis);
    try std.testing.expectEqualSlices([]const u8, &.{ "--raw", "--no-abbrev", "-z" }, raw.argv[12 .. raw.argv.len - 2]);

    var numstat = try buildDiffCommand(std.testing.allocator, basis, .numstat_z);
    defer numstat.deinit(std.testing.allocator);
    try expectCommandPrefix(numstat, basis);
    try std.testing.expectEqualSlices([]const u8, &.{ "--numstat", "-z" }, numstat.argv[12 .. numstat.argv.len - 2]);
}

test "History preview real Git projections override ambient rename and copy settings" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "rename-old.txt", .data = "rename content\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "copy-source.txt", .data = "copy candidate\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "rename-old.txt", "copy-source.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });

    const before_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(before_output);
    const before = try ObjectId.parse(.sha1, try testOutputLine(before_output));

    try runTestGit(io, tmp.dir, &.{ "git", "mv", "rename-old.txt", "rename-new.txt" });
    try tmp.dir.writeFile(io, .{ .sub_path = "copy-source.txt", .data = "copy candidate\nmodified\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "copy-new.txt", .data = "copy candidate\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "--all" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "rename and copy candidate" });

    const after_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(after_output);
    const after = try ObjectId.parse(.sha1, try testOutputLine(after_output));
    const basis: Basis = .{
        .object_format = .sha1,
        .before = .{ .commit = before },
        .after = after,
    };

    const explicit_copy = try testGitOutput(io, tmp.dir, &.{
        "git", "diff", "--find-copies", "--raw", "--no-abbrev", "-z", before.slice(), after.slice(),
    });
    defer std.testing.allocator.free(explicit_copy);
    try std.testing.expect(std.mem.indexOf(u8, explicit_copy, " C100\x00copy-source.txt\x00copy-new.txt\x00") != null);

    try runTestGit(io, tmp.dir, &.{ "git", "config", "diff.renames", "false" });
    try expectHistoryPreviewRenamePolicyOutput(io, tmp.dir, basis);

    try runTestGit(io, tmp.dir, &.{ "git", "config", "diff.renames", "copies" });
    try expectHistoryPreviewRenamePolicyOutput(io, tmp.dir, basis);
}

test "History preview Basis admission distinguishes exact endpoint terminals" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "content\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });

    const commit_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(commit_output);
    const commit_oid = try ObjectId.parse(.sha1, try testOutputLine(commit_output));
    const tree_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD^{tree}" });
    defer std.testing.allocator.free(tree_output);
    const tree_oid = try ObjectId.parse(.sha1, try testOutputLine(tree_output));
    const missing_oid = try ObjectId.parse(.sha1, "0000000000000000000000000000000000000000");
    const sha256_missing = try ObjectId.parse(.sha256, "0000000000000000000000000000000000000000000000000000000000000000");

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };

    try expectAdmitted(try admitBasis(std.testing.allocator, io, context, .{
        .object_format = .sha1,
        .before = .{ .commit = commit_oid },
        .after = commit_oid,
    }));
    try expectAdmitted(try admitBasis(std.testing.allocator, io, context, .{
        .object_format = .sha1,
        .before = .empty_tree,
        .after = commit_oid,
    }));
    try expectAdmissionFailure(try admitBasis(std.testing.allocator, io, context, .{
        .object_format = .sha1,
        .before = .{ .commit = missing_oid },
        .after = commit_oid,
    }), .before_missing);
    try expectAdmissionFailure(try admitBasis(std.testing.allocator, io, context, .{
        .object_format = .sha1,
        .before = .{ .commit = tree_oid },
        .after = commit_oid,
    }), .before_wrong_kind);
    try expectAdmissionFailure(try admitBasis(std.testing.allocator, io, context, .{
        .object_format = .sha1,
        .before = .{ .commit = commit_oid },
        .after = missing_oid,
    }), .after_missing);
    try expectAdmissionFailure(try admitBasis(std.testing.allocator, io, context, .{
        .object_format = .sha1,
        .before = .{ .commit = commit_oid },
        .after = tree_oid,
    }), .after_wrong_kind);
    try expectAdmissionFailure(try admitBasis(std.testing.allocator, io, context, .{
        .object_format = .sha256,
        .before = .{ .commit = sha256_missing },
        .after = sha256_missing,
    }), .repository_format_drift);

    var non_repository = std.testing.tmpDir(.{});
    defer non_repository.cleanup();
    try non_repository.dir.writeFile(io, .{
        .sub_path = ".git",
        .data = "gitdir: /definitely/missing-history-preview-repository\n",
    });
    const non_repository_context: git_command.DirectoryContext = .{
        .cwd = non_repository.dir,
        .environment = &environment,
    };
    try expectAdmissionFailure(try admitBasis(std.testing.allocator, io, non_repository_context, .{
        .object_format = .sha1,
        .before = .{ .commit = commit_oid },
        .after = commit_oid,
    }), .git_command_failed);

    var invalid = commit_oid;
    invalid.len = 1;
    try expectAdmissionFailure(try admitBasis(std.testing.allocator, io, context, .{
        .object_format = .sha1,
        .before = .{ .commit = commit_oid },
        .after = invalid,
    }), .invalid_basis);
}

test "Compare target resolution ahead count and History basis share exact patch bytes" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try runTestGit(io, tmp.dir, &.{ "git", "switch", "-c", "feature" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\nfeature\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "feature" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const resolved = try resolveTarget(std.testing.allocator, io, context, .{
        .base = "refs/heads/main",
        .head = "HEAD",
    });
    const target = switch (resolved) {
        .target => |value| value,
        .failure => return error.ExpectedTarget,
    };
    try std.testing.expect(target.base_oid.eql(&target.diff_base_oid));

    const ahead = try computeAhead(std.testing.allocator, io, context, target);
    try std.testing.expectEqual(@as(u64, 1), switch (ahead) {
        .count => |count| count,
        .failure => return error.ExpectedAheadCount,
    });

    var target_materialized = try materializeTarget(std.testing.allocator, io, context, target);
    defer target_materialized.deinit(std.testing.allocator);
    const target_patch = switch (target_materialized) {
        .materialization => |*value| value.patch_bytes,
        .failure => return error.ExpectedTargetMaterialization,
    };
    try std.testing.expect(std.mem.indexOf(u8, target_patch, "+feature") != null);

    var basis_materialized = try materializeBasis(std.testing.allocator, io, context, .{
        .object_format = target.object_format,
        .before = .{ .commit = target.diff_base_oid },
        .after = target.head_oid,
    });
    defer basis_materialized.deinit(std.testing.allocator);
    const basis_patch = switch (basis_materialized) {
        .materialization => |*value| value.patch_bytes,
        .failure => return error.ExpectedBasisMaterialization,
    };
    try std.testing.expectEqualSlices(u8, target_patch, basis_patch);
}

test "committed attributes ignore replacement dirty worktree index and untracked files" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.createDir(io, "nested", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.dat -diff\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data.dat", .data = "old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/data.dat", .data = "nested old\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", ".gitattributes", "data.dat", "nested/data.dat" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try runTestGit(io, tmp.dir, &.{ "git", "switch", "-c", "feature" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.dat diff\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data.dat", .data = "new\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/data.dat", .data = "nested new\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", ".gitattributes", "data.dat", "nested/data.dat" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "feature" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .base = "main",
        .head = "HEAD",
    }));
    var clean = try materializeTarget(std.testing.allocator, io, context, target);
    defer clean.deinit(std.testing.allocator);
    const clean_patch = switch (clean) {
        .materialization => |*value| value.patch_bytes,
        .failure => return error.ExpectedTargetMaterialization,
    };
    try std.testing.expect(std.mem.indexOf(u8, clean_patch, "+new") != null);
    try std.testing.expect(std.mem.indexOf(u8, clean_patch, "+nested new") != null);

    try runTestGit(io, tmp.dir, &.{ "git", "replace", target.head_oid.slice(), target.base_oid.slice() });
    const replacement_target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .base = "main",
        .head = "HEAD",
    }));
    try std.testing.expect(target.eql(&replacement_target));
    var replacement_ignored = try materializeTarget(std.testing.allocator, io, context, target);
    defer replacement_ignored.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, clean_patch, replacement_ignored.materialization.patch_bytes);

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.dat -diff\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data.dat", .data = "dirty worktree\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/data.dat", .data = "nested dirty worktree\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "untracked.dat", .data = "untracked content\n" });
    var dirty = try materializeTarget(std.testing.allocator, io, context, target);
    defer dirty.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, clean_patch, dirty.materialization.patch_bytes);

    try runTestGit(io, tmp.dir, &.{ "git", "add", ".gitattributes", "data.dat", "nested/data.dat" });
    var staged = try materializeTarget(std.testing.allocator, io, context, target);
    defer staged.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, clean_patch, staged.materialization.patch_bytes);
}

test "materialization accepts exact sixteen MiB and rejects the next stdout byte" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "large.txt diff\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", ".gitattributes" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try runTestGit(io, tmp.dir, &.{ "git", "switch", "-c", "boundary" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };

    const sample_size: usize = 4096;
    const sample = try std.testing.allocator.alloc(u8, sample_size);
    @memset(sample, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = sample });
    std.testing.allocator.free(sample);
    try runTestGit(io, tmp.dir, &.{ "git", "add", "large.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "sample" });
    const sample_target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .base = "refs/heads/main",
        .head = "HEAD",
    }));
    const sample_patch = try testRawPatch(io, tmp.dir, sample_target);
    defer std.testing.allocator.free(sample_patch);
    try std.testing.expect(sample_patch.len > sample_size);
    const fixed_overhead = sample_patch.len - sample_size;
    try std.testing.expect(fixed_overhead < max_patch_bytes);
    const exact_file_size = max_patch_bytes - fixed_overhead;

    try runTestGit(io, tmp.dir, &.{ "git", "reset", "--hard", "refs/heads/main" });
    const exact_bytes = try std.testing.allocator.alloc(u8, exact_file_size);
    @memset(exact_bytes, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = exact_bytes });
    std.testing.allocator.free(exact_bytes);
    try runTestGit(io, tmp.dir, &.{ "git", "add", "large.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "exact" });
    const exact_target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .base = "refs/heads/main",
        .head = "HEAD",
    }));
    var exact = try materializeTarget(std.testing.allocator, io, context, exact_target);
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_patch_bytes, exact.materialization.patch_bytes.len);

    try runTestGit(io, tmp.dir, &.{ "git", "reset", "--hard", "refs/heads/main" });
    const over_bytes = try std.testing.allocator.alloc(u8, exact_file_size + 1);
    @memset(over_bytes, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = over_bytes });
    std.testing.allocator.free(over_bytes);
    try runTestGit(io, tmp.dir, &.{ "git", "add", "large.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "over" });
    const over_target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .base = "refs/heads/main",
        .head = "HEAD",
    }));
    var over = try materializeTarget(std.testing.allocator, io, context, over_target);
    defer over.deinit(std.testing.allocator);
    try std.testing.expectEqual(MaterializationFailure.projection_too_large, over.failure);
}

test "partial clone missing blob fails materialization without helpers or object writes" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "source", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{});
    defer source.close(io);
    try runTestGit(io, source, &.{ "git", "init", "--initial-branch=main" });
    try source.writeFile(io, .{ .sub_path = "blob.txt", .data = "base blob\n" });
    try runTestGit(io, source, &.{ "git", "add", "blob.txt" });
    try runTestGit(io, source, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    const base_output = try testGitOutput(io, source, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(base_output);
    const base_oid = try testOutputLine(base_output);
    try source.writeFile(io, .{ .sub_path = "blob.txt", .data = "head blob\n" });
    try runTestGit(io, source, &.{ "git", "add", "blob.txt" });
    try runTestGit(io, source, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });
    const head_output = try testGitOutput(io, source, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_output);
    const head_oid = try testOutputLine(head_output);
    const blob_output = try testGitOutput(io, source, &.{ "git", "rev-parse", "HEAD:blob.txt" });
    defer std.testing.allocator.free(blob_output);
    const blob_oid = try testOutputLine(blob_output);

    try runTestGit(io, tmp.dir, &.{ "git", "clone", "--bare", "source", "origin.git" });
    var origin = try tmp.dir.openDir(io, "origin.git", .{});
    defer origin.close(io);
    try runTestGit(io, origin, &.{ "git", "config", "uploadpack.allowFilter", "true" });
    const origin_path = try tmp.dir.realPathFileAlloc(io, "origin.git", std.testing.allocator);
    defer std.testing.allocator.free(origin_path);
    const origin_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{origin_path});
    defer std.testing.allocator.free(origin_url);
    try runTestGit(io, tmp.dir, &.{ "git", "clone", "--filter=blob:none", "--no-checkout", origin_url, "partial" });
    var partial = try tmp.dir.openDir(io, "partial", .{});
    defer partial.close(io);

    const missing_check = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "git", "--no-lazy-fetch", "cat-file", "-e", blob_oid },
        .cwd = .{ .dir = partial },
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(stderr_capture_bytes),
    });
    defer freeRunResult(std.testing.allocator, missing_check);
    try std.testing.expect(!termExited(missing_check.term, 0));

    try tmp.dir.createDir(io, "helpers", .default_dir);
    const temp_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(temp_root);
    const helpers_path = try std.fs.path.join(std.testing.allocator, &.{ temp_root, "helpers" });
    defer std.testing.allocator.free(helpers_path);
    const remote_marker = try std.fs.path.join(std.testing.allocator, &.{ temp_root, "remote-helper-invoked" });
    defer std.testing.allocator.free(remote_marker);
    const credential_marker = try std.fs.path.join(std.testing.allocator, &.{ temp_root, "credential-helper-invoked" });
    defer std.testing.allocator.free(credential_marker);
    const remote_script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\nprintf invoked > '{s}'\nexit 1\n", .{remote_marker});
    defer std.testing.allocator.free(remote_script);
    const credential_script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\nprintf invoked > '{s}'\nexit 1\n", .{credential_marker});
    defer std.testing.allocator.free(credential_script);
    try tmp.dir.writeFile(io, .{ .sub_path = "helpers/git-remote-fake", .data = remote_script });
    try tmp.dir.writeFile(io, .{ .sub_path = "helpers/credential-helper", .data = credential_script });
    try runTestGit(io, tmp.dir, &.{ "chmod", "+x", "helpers/git-remote-fake", "helpers/credential-helper" });
    const credential_path = try std.fs.path.join(std.testing.allocator, &.{ helpers_path, "credential-helper" });
    defer std.testing.allocator.free(credential_path);
    const credential_config = try std.fmt.allocPrint(std.testing.allocator, "!{s}", .{credential_path});
    defer std.testing.allocator.free(credential_config);
    try runTestGit(io, partial, &.{ "git", "remote", "set-url", "origin", "fake::missing" });
    try runTestGit(io, partial, &.{ "git", "config", "credential.helper", credential_config });

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    const helper_path_env = try std.fmt.allocPrint(std.testing.allocator, "{s}:/usr/bin:/bin", .{helpers_path});
    defer std.testing.allocator.free(helper_path_env);
    try parent.put("PATH", helper_path_env);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, &parent);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = partial, .environment = &environment };

    const status_before = try testGitOutput(io, partial, &.{ "git", "status", "--porcelain=v2", "--untracked-files=no" });
    defer std.testing.allocator.free(status_before);
    const inventory_before = try objectInventory(std.testing.allocator, io, partial);
    defer std.testing.allocator.free(inventory_before);

    const target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .base = base_oid,
        .head = head_oid,
    }));
    const ahead = try computeAhead(std.testing.allocator, io, context, target);
    try std.testing.expectEqual(@as(u64, 1), ahead.count);
    var materialization = try materializeTarget(std.testing.allocator, io, context, target);
    defer materialization.deinit(std.testing.allocator);
    try std.testing.expectEqual(MaterializationFailure.projection_git_command_failed, materialization.failure);

    const status_after = try testGitOutput(io, partial, &.{ "git", "status", "--porcelain=v2", "--untracked-files=no" });
    defer std.testing.allocator.free(status_after);
    try std.testing.expectEqualSlices(u8, status_before, status_after);
    const inventory_after = try objectInventory(std.testing.allocator, io, partial);
    defer std.testing.allocator.free(inventory_after);
    try std.testing.expectEqualSlices(u8, inventory_before, inventory_after);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "remote-helper-invoked", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "credential-helper-invoked", .{}));
}

test "promisor missing endpoint and graph stay typed without helper or object effects" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "graph\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "root" });
    const root_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(root_output);
    const root_oid = try testOutputLine(root_output);
    const tree_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD^{tree}" });
    defer std.testing.allocator.free(tree_output);
    const tree_oid = try testOutputLine(tree_output);
    const base_output = try testGitOutput(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-p", root_oid, "-m", "base" });
    defer std.testing.allocator.free(base_output);
    const base_oid = try testOutputLine(base_output);
    const head_output = try testGitOutput(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-p", root_oid, "-m", "head" });
    defer std.testing.allocator.free(head_output);
    const head_oid = try testOutputLine(head_output);

    try runTestGit(io, tmp.dir, &.{ "git", "config", "core.repositoryformatversion", "1" });
    try runTestGit(io, tmp.dir, &.{ "git", "config", "extensions.partialClone", "origin" });
    try runTestGit(io, tmp.dir, &.{ "git", "config", "remote.origin.promisor", "true" });
    try runTestGit(io, tmp.dir, &.{ "git", "config", "remote.origin.partialclonefilter", "blob:none" });
    try runTestGit(io, tmp.dir, &.{ "git", "config", "remote.origin.url", "fake::missing" });
    try tmp.dir.createDir(io, "helpers", .default_dir);
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const marker_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "remote-helper-invoked" });
    defer std.testing.allocator.free(marker_path);
    const helper_script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\nprintf invoked > '{s}'\nexit 1\n", .{marker_path});
    defer std.testing.allocator.free(helper_script);
    try tmp.dir.writeFile(io, .{ .sub_path = "helpers/git-remote-fake", .data = helper_script });
    try runTestGit(io, tmp.dir, &.{ "chmod", "+x", "helpers/git-remote-fake" });
    const helpers_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "helpers" });
    defer std.testing.allocator.free(helpers_path);

    const missing_path = try std.fmt.allocPrint(std.testing.allocator, ".git/objects/{s}/{s}", .{ root_oid[0..2], root_oid[2..] });
    defer std.testing.allocator.free(missing_path);
    try tmp.dir.deleteFile(io, missing_path);
    const missing_ref = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{root_oid});
    defer std.testing.allocator.free(missing_ref);
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/MISSING", .data = missing_ref });

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    const path_env = try std.fmt.allocPrint(std.testing.allocator, "{s}:/usr/bin:/bin", .{helpers_path});
    defer std.testing.allocator.free(path_env);
    try parent.put("PATH", path_env);
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, &parent);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const inventory_before = try objectInventory(std.testing.allocator, io, tmp.dir);
    defer std.testing.allocator.free(inventory_before);

    const graph = try resolveTarget(std.testing.allocator, io, context, .{
        .base = base_oid,
        .head = head_oid,
    });
    try std.testing.expectEqual(TargetResolutionFailure.target_graph_unavailable, graph.failure);
    const endpoint_missing = try resolveTarget(std.testing.allocator, io, context, .{
        .base = "MISSING",
        .head = head_oid,
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_object_unavailable, endpoint_missing.failure);
    const endpoint_missing_with_suffix = try resolveTarget(std.testing.allocator, io, context, .{
        .base = "MISSING^{commit}",
        .head = head_oid,
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_object_unavailable, endpoint_missing_with_suffix.failure);

    const inventory_after = try objectInventory(std.testing.allocator, io, tmp.dir);
    defer std.testing.allocator.free(inventory_after);
    try std.testing.expectEqualSlices(u8, inventory_before, inventory_after);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "remote-helper-invoked", .{}));
}

test "ambiguous endpoint stays rejected and resolver pins endpoints before refs move at merge-base" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    const base_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(base_output);
    const base_oid = try testOutputLine(base_output);
    try runTestGit(io, tmp.dir, &.{ "git", "switch", "-c", "feature" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\nhead\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });
    const head_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_output);
    const head_oid = try testOutputLine(head_output);

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    try runTestGit(io, tmp.dir, &.{ "git", "branch", "collision", "main" });
    try runTestGit(io, tmp.dir, &.{ "git", "tag", "collision", "feature" });
    const collision = try resolveTarget(std.testing.allocator, io, context, .{
        .base = "collision",
        .head = "HEAD",
    });
    try std.testing.expectEqual(TargetResolutionFailure.base_ambiguous, collision.failure);

    var movement: RefMovementTestContext = .{
        .base_ref = "refs/heads/main",
        .new_base_oid = head_oid,
        .head_ref = "refs/heads/feature",
        .new_head_oid = base_oid,
    };
    const target = try expectTarget(try resolveTargetWithTestHook(
        std.testing.allocator,
        io,
        context,
        .{
            .base = "refs/heads/main",
            .head = "refs/heads/feature",
        },
        .{
            .context = &movement,
            .after_endpoints = RefMovementTestContext.move,
        },
    ));
    try std.testing.expectEqualStrings(base_oid, target.base_oid.slice());
    try std.testing.expectEqualStrings(head_oid, target.head_oid.slice());
    const moved_base_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "refs/heads/main" });
    defer std.testing.allocator.free(moved_base_output);
    try std.testing.expectEqualStrings(head_oid, try testOutputLine(moved_base_output));
    const moved_head_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "refs/heads/feature" });
    defer std.testing.allocator.free(moved_head_output);
    try std.testing.expectEqualStrings(base_oid, try testOutputLine(moved_head_output));

    const ahead = try computeAhead(std.testing.allocator, io, context, target);
    try std.testing.expectEqual(@as(u64, 1), ahead.count);
    var materialization = try materializeTarget(std.testing.allocator, io, context, target);
    defer materialization.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, materialization.materialization.patch_bytes, "+head") != null);
}

test "SHA-256 root basis materializes when Git supports the object format" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const init = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "git", "init", "--object-format=sha256", "--initial-branch=main" },
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, init);
    if (!termExited(init.term, 0)) return error.SkipZigTest;

    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "sha256\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "sha256" });
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const target = try expectTarget(try resolveTarget(std.testing.allocator, io, context, .{
        .base = "refs/heads/main",
        .head = "HEAD",
    }));
    try std.testing.expectEqual(ObjectFormat.sha256, target.object_format);
    try std.testing.expectEqual(@as(u8, 64), target.head_oid.len);
    const root_basis: Basis = .{
        .object_format = .sha256,
        .before = .empty_tree,
        .after = target.head_oid,
    };
    try expectAdmitted(try admitBasis(std.testing.allocator, io, context, root_basis));
    var root = try materializeBasis(std.testing.allocator, io, context, root_basis);
    defer root.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, root.materialization.patch_bytes, "+sha256") != null);
}

test "resolver separates no merge base from multiple best merge bases" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "graph\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "root" });
    const root_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(root_output);
    const root_oid = try testOutputLine(root_output);
    const tree_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD^{tree}" });
    defer std.testing.allocator.free(tree_output);
    const tree_oid = try testOutputLine(tree_output);
    const orphan_output = try testGitOutput(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-m", "orphan" });
    defer std.testing.allocator.free(orphan_output);
    const orphan_oid = try testOutputLine(orphan_output);

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const no_merge = try resolveTarget(std.testing.allocator, io, context, .{
        .base = root_oid,
        .head = orphan_oid,
    });
    try std.testing.expectEqual(TargetResolutionFailure.no_merge_base, no_merge.failure);

    const a1_output = try testGitOutput(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-p", root_oid, "-m", "a1" });
    defer std.testing.allocator.free(a1_output);
    const a1 = try testOutputLine(a1_output);
    const b1_output = try testGitOutput(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-p", root_oid, "-m", "b1" });
    defer std.testing.allocator.free(b1_output);
    const b1 = try testOutputLine(b1_output);
    const a2_output = try testGitOutput(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-p", a1, "-p", b1, "-m", "a2" });
    defer std.testing.allocator.free(a2_output);
    const a2 = try testOutputLine(a2_output);
    const b2_output = try testGitOutput(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", tree_oid, "-p", b1, "-p", a1, "-m", "b2" });
    defer std.testing.allocator.free(b2_output);
    const b2 = try testOutputLine(b2_output);
    const multiple = try resolveTarget(std.testing.allocator, io, context, .{
        .base = a2,
        .head = b2,
    });
    try std.testing.expectEqual(TargetResolutionFailure.ambiguous_merge_base, multiple.failure);
}
