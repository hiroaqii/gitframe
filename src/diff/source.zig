const std = @import("std");
const git_command = @import("../git/command.zig");
const git_read = @import("../git/read.zig");

/// User-selected source for the raw unified diff text.
///
/// Working-tree Changes, a patch file, or a committed range.
pub const SourceMode = union(enum) {
    unstaged,
    patch_file: []const u8,
    range: []const u8,
};

pub const AutoReloadOverride = enum {
    inherit,
    enabled,
    disabled,
};

pub const CliConfig = struct {
    source: SourceMode = .unstaged,
    auto_reload: AutoReloadOverride = .inherit,
    stats_summary: bool = false,
    version: bool = false,

    pub fn sourceLabel(self: CliConfig) []const u8 {
        return switch (self.source) {
            .unstaged => "working tree changes",
            .patch_file => |path| path,
            .range => |range| range,
        };
    }
};

/// Concrete load request used by backends.
///
/// `source` answers "what diff should be read"; `repo_root` answers "where a
/// Git command should run". Patch files can leave `repo_root` null because they do not execute Git.
pub const LoadRequest = struct {
    source: SourceMode,
    repo_root: ?[]const u8 = null,

    pub fn requiresRepo(self: LoadRequest) bool {
        return sourceRequiresRepo(self.source);
    }

    pub fn deinit(self: LoadRequest, allocator: std.mem.Allocator) void {
        freeLoadRequest(allocator, self);
    }
};

pub fn sourceRequiresRepo(source: SourceMode) bool {
    return switch (source) {
        .unstaged, .range => true,
        .patch_file => false,
    };
}

pub fn sourceAllowsStageAction(source: SourceMode) bool {
    return switch (source) {
        .unstaged => true,
        .patch_file, .range => false,
    };
}

pub fn sourceAllowsUnstageAction(source: SourceMode) bool {
    return switch (source) {
        .unstaged => true,
        .patch_file, .range => false,
    };
}

pub fn sourceAllowsDiscardAction(source: SourceMode) bool {
    return switch (source) {
        .unstaged => true,
        .patch_file, .range => false,
    };
}

pub fn sourceAllowsStageProjection(source: SourceMode) bool {
    return switch (source) {
        .unstaged => true,
        .patch_file, .range => false,
    };
}

pub fn sourceAllowsEditorAction(source: SourceMode) bool {
    return switch (source) {
        .unstaged => true,
        .patch_file, .range => false,
    };
}

/// Whether a Changes model has current-repository path authority for a direct
/// Repository page link. Repository-backed history still lacks a claim about
/// the current working-tree surface, so `range` remains intentionally false.
pub fn sourceAllowsRepositoryLink(source: SourceMode) bool {
    return switch (source) {
        .unstaged => true,
        .patch_file, .range => false,
    };
}

pub const ParseArgsError = error{
    UnknownOption,
    MissingOptionValue,
    InvalidRange,
    TooManyInputs,
    ConflictingSourceMode,
    ConflictingWatchOverride,
};

pub const LoadError = git_command.Error || error{
    ReadFailed,
    MissingRepoRoot,
};

pub const LoadResult = git_read.LoadResult;

/// Borrowed execution context for one synchronous source load. Async owners
/// keep the corresponding descriptor/environment alive in their task.
pub const LoadContext = union(enum) {
    repository: git_command.DirectoryContext,
    none,
};

pub fn parseArgs(args: []const []const u8) ParseArgsError!CliConfig {
    var config: CliConfig = .{};
    var input_count: usize = 0;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--watch")) {
            if (config.auto_reload == .disabled) return error.ConflictingWatchOverride;
            config.auto_reload = .enabled;
        } else if (std.mem.eql(u8, arg, "--no-watch")) {
            if (config.auto_reload == .enabled) return error.ConflictingWatchOverride;
            config.auto_reload = .disabled;
        } else if (std.mem.eql(u8, arg, "--stats-summary")) {
            config.stats_summary = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            config.version = true;
        } else if (std.mem.eql(u8, arg, "--range")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            if (isOptionLikeValue(args[index])) return error.InvalidRange;
            try setSourceMode(&config, .{ .range = args[index] });
        } else if (std.mem.startsWith(u8, arg, "--range=")) {
            const value = arg["--range=".len..];
            if (value.len == 0) return error.MissingOptionValue;
            if (isOptionLikeValue(value)) return error.InvalidRange;
            try setSourceMode(&config, .{ .range = value });
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            input_count += 1;
            if (input_count > 1) return error.TooManyInputs;
            try setSourceMode(&config, .{ .patch_file = arg });
        }
    }

    return config;
}

fn isOptionLikeValue(value: []const u8) bool {
    return value.len > 0 and value[0] == '-';
}

fn setSourceMode(config: *CliConfig, source: SourceMode) ParseArgsError!void {
    if (config.source != .unstaged) return error.ConflictingSourceMode;
    config.source = source;
}

pub fn cloneSource(allocator: std.mem.Allocator, source: SourceMode) std.mem.Allocator.Error!SourceMode {
    return switch (source) {
        .unstaged => .unstaged,
        .patch_file => |path| .{ .patch_file = try allocator.dupe(u8, path) },
        .range => |range| .{ .range = try allocator.dupe(u8, range) },
    };
}

pub fn cloneLoadRequest(allocator: std.mem.Allocator, request: LoadRequest) std.mem.Allocator.Error!LoadRequest {
    const source = try cloneSource(allocator, request.source);
    errdefer freeSource(allocator, source);

    return .{
        .source = source,
        .repo_root = if (request.repo_root) |repo_root| try allocator.dupe(u8, repo_root) else null,
    };
}

pub fn freeSource(allocator: std.mem.Allocator, source: SourceMode) void {
    switch (source) {
        .patch_file => |path| allocator.free(path),
        .range => |range| allocator.free(range),
        else => {},
    }
}

pub fn freeLoadRequest(allocator: std.mem.Allocator, request: LoadRequest) void {
    freeSource(allocator, request.source);
    if (request.repo_root) |repo_root| allocator.free(repo_root);
}

/// Convenience entry point for terminal mode.
///
/// Patch files are read locally; repository sources use the Git backend.
pub fn load(allocator: std.mem.Allocator, io: std.Io, request: LoadRequest, context: LoadContext) LoadError!LoadResult {
    return switch (request.source) {
        .patch_file => |path| .{ .ok = readPatchFile(allocator, io, path) catch |err| return mapReadError(err) },
        .unstaged, .range => git_read.loadDiff(allocator, io, .{
            .context = switch (context) {
                .repository => |repository| repository,
                .none => return error.MissingRepoRoot,
            },
            .kind = switch (request.source) {
                .unstaged => .unstaged,
                .range => |range| .{ .range = range },
                .patch_file => unreachable,
            },
        }),
    };
}

fn readPatchFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(git_read.max_diff_bytes));
}

fn mapReadError(err: anyerror) LoadError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.ReadFailed,
    };
}

test "parseArgs defaults to unstaged diff" {
    const args = [_][]const u8{"gitframe"};
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .unstaged);
    try std.testing.expect(!config.version);
}

test "parseArgs accepts version with remaining startup options" {
    try std.testing.expect((try parseArgs(&.{ "gitframe", "--version" })).version);
    const patch = try parseArgs(&.{ "gitframe", "--version", "--watch", "--stats-summary", "missing.patch" });
    try std.testing.expect(patch.version and patch.stats_summary);
    try std.testing.expect(patch.auto_reload == .enabled and patch.source == .patch_file);
    const range = try parseArgs(&.{ "gitframe", "--range=HEAD..HEAD", "--no-watch", "--version" });
    try std.testing.expect(range.version and range.auto_reload == .disabled and range.source == .range);
}

test "parseArgs validates all arguments before version output" {
    const cases = [_]struct { args: []const []const u8, err: ParseArgsError }{
        .{ .args = &.{ "gitframe", "--cached", "--version" }, .err = error.UnknownOption },
        .{ .args = &.{ "gitframe", "--version", "--unknown" }, .err = error.UnknownOption },
        .{ .args = &.{ "gitframe", "--version", "--range" }, .err = error.MissingOptionValue },
        .{ .args = &.{ "gitframe", "--version", "--range=-bad" }, .err = error.InvalidRange },
        .{ .args = &.{ "gitframe", "--version", "a.patch", "b.patch" }, .err = error.TooManyInputs },
        .{ .args = &.{ "gitframe", "--version", "--range=HEAD..HEAD", "a.patch" }, .err = error.ConflictingSourceMode },
        .{ .args = &.{ "gitframe", "--watch", "--version", "--no-watch" }, .err = error.ConflictingWatchOverride },
    };
    for (cases) |case| try std.testing.expectError(case.err, parseArgs(case.args));
}

test "parseArgs accepts watch mode" {
    const args = [_][]const u8{ "gitframe", "--watch" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .unstaged);
    try std.testing.expectEqual(AutoReloadOverride.enabled, config.auto_reload);
}

test "parseArgs keeps auto reload inherited without flags" {
    const args = [_][]const u8{"gitframe"};
    const config = try parseArgs(args[0..]);

    try std.testing.expectEqual(AutoReloadOverride.inherit, config.auto_reload);
}

test "parseArgs accepts no-watch override and rejects conflicts" {
    const disabled_args = [_][]const u8{ "gitframe", "--no-watch" };
    const disabled = try parseArgs(disabled_args[0..]);
    try std.testing.expectEqual(AutoReloadOverride.disabled, disabled.auto_reload);

    const watch_first = [_][]const u8{ "gitframe", "--watch", "--no-watch" };
    try std.testing.expectError(error.ConflictingWatchOverride, parseArgs(watch_first[0..]));

    const no_watch_first = [_][]const u8{ "gitframe", "--no-watch", "--watch" };
    try std.testing.expectError(error.ConflictingWatchOverride, parseArgs(no_watch_first[0..]));
}

test "parseArgs accepts stats summary mode" {
    const args = [_][]const u8{ "gitframe", "--stats-summary" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.stats_summary);
}

test "parseArgs rejects removed review mode" {
    const args = [_][]const u8{ "gitframe", "--review" };
    try std.testing.expectError(error.UnknownOption, parseArgs(args[0..]));
}

test "parseArgs accepts range option" {
    const args = [_][]const u8{ "gitframe", "--range", "main...HEAD" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .range);
    try std.testing.expectEqualStrings("main...HEAD", config.source.range);
}

test "parseArgs rejects option-like range values" {
    const equals_form = [_][]const u8{ "gitframe", "--range=--output=/tmp/gitframe.diff" };
    try std.testing.expectError(error.InvalidRange, parseArgs(equals_form[0..]));

    const separate_value = [_][]const u8{ "gitframe", "--range", "--output=/tmp/gitframe.diff" };
    try std.testing.expectError(error.InvalidRange, parseArgs(separate_value[0..]));
}

test "parseArgs accepts patch file path" {
    const args = [_][]const u8{ "gitframe", "change.diff" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .patch_file);
    try std.testing.expectEqualStrings("change.diff", config.source.patch_file);
}

test "parseArgs rejects conflicting source modes" {
    const args = [_][]const u8{ "gitframe", "--range", "main...HEAD", "change.diff" };
    try std.testing.expectError(error.ConflictingSourceMode, parseArgs(args[0..]));
}

test "cloneSource duplicates payload source modes" {
    const allocator = std.testing.allocator;
    const source = try cloneSource(allocator, .{ .range = "main...HEAD" });
    defer freeSource(allocator, source);

    try std.testing.expect(source == .range);
    try std.testing.expectEqualStrings("main...HEAD", source.range);
}

test "LoadRequest identifies sources that require a repo root" {
    try std.testing.expect((LoadRequest{ .source = .unstaged }).requiresRepo());
    try std.testing.expect((LoadRequest{ .source = .{ .range = "main...HEAD" } }).requiresRepo());

    try std.testing.expect(!(LoadRequest{ .source = .{ .patch_file = "change.diff" } }).requiresRepo());
}

test "working tree source supports actions and stage projection" {
    try std.testing.expect(sourceAllowsStageAction(.unstaged));
    try std.testing.expect(!sourceAllowsStageAction(.{ .range = "main...HEAD" }));

    try std.testing.expect(sourceAllowsUnstageAction(.unstaged));
    try std.testing.expect(!sourceAllowsUnstageAction(.{ .range = "main...HEAD" }));

    try std.testing.expect(sourceAllowsDiscardAction(.unstaged));
    try std.testing.expect(!sourceAllowsDiscardAction(.{ .range = "main...HEAD" }));

    try std.testing.expect(sourceAllowsStageProjection(.unstaged));
    try std.testing.expect(!sourceAllowsStageProjection(.{ .range = "main...HEAD" }));

    try std.testing.expect(sourceAllowsEditorAction(.unstaged));
    try std.testing.expect(!sourceAllowsEditorAction(.{ .range = "main...HEAD" }));
}

test "repository link accepts only current repository Changes sources" {
    try std.testing.expect(sourceAllowsRepositoryLink(.unstaged));
    try std.testing.expect(!sourceAllowsRepositoryLink(.{ .patch_file = "change.patch" }));
    try std.testing.expect(!sourceAllowsRepositoryLink(.{ .range = "HEAD~1..HEAD" }));
}

test "cloneLoadRequest duplicates source payload and repo root" {
    const allocator = std.testing.allocator;
    const request = try cloneLoadRequest(allocator, .{
        .source = .{ .range = "main...HEAD" },
        .repo_root = "/repo",
    });
    defer freeLoadRequest(allocator, request);

    try std.testing.expect(request.source == .range);
    try std.testing.expectEqualStrings("main...HEAD", request.source.range);
    try std.testing.expectEqualStrings("/repo", request.repo_root.?);
}

test "load requires repo root before routing git sources to backend" {
    try std.testing.expectError(error.MissingRepoRoot, load(std.testing.allocator, std.testing.io, .{
        .source = .unstaged,
        .repo_root = null,
    }, .none));
}

test "parseArgs rejects removed startup options" {
    for ([_][]const u8{ "--stdin", "--pager", "--difftool", "--export-context", "--cached" }) |option| {
        try std.testing.expectError(error.UnknownOption, parseArgs(&.{ "gitframe", option }));
    }
}
