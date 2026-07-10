const std = @import("std");
const git_backend = @import("../git/backend.zig");

/// User-selected source for the raw unified diff text.
///
/// Terminal mode can read all variants directly. Browser mode can later reuse
/// the same shape while swapping the backend behind it.
pub const SourceMode = union(enum) {
    unstaged,
    cached,
    stdin,
    pager: []const u8,
    patch_file: []const u8,
    range: []const u8,
    no_index: PathPair,
};

pub const PathPair = struct {
    left: []const u8,
    right: []const u8,
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
    export_context: bool = false,
    review_mode: bool = false,

    pub fn sourceLabel(self: CliConfig) []const u8 {
        return switch (self.source) {
            .unstaged => "unstaged changes",
            .cached => "staged changes",
            .stdin => "stdin diff",
            .pager => "pager diff",
            .patch_file => |path| path,
            .range => |range| range,
            .no_index => "difftool",
        };
    }
};

/// Concrete load request used by backends.
///
/// `source` answers "what diff should be read"; `repo_root` answers "where a
/// Git command should run". Raw text sources such as stdin and patch files can
/// leave `repo_root` null because they do not execute Git.
pub const LoadRequest = struct {
    source: SourceMode,
    repo_root: ?[]const u8 = null,

    pub fn requiresRepo(self: LoadRequest) bool {
        return sourceRequiresRepo(self.source);
    }
};

pub fn sourceRequiresRepo(source: SourceMode) bool {
    return switch (source) {
        .unstaged, .cached, .range => true,
        .stdin, .pager, .patch_file, .no_index => false,
    };
}

pub fn sourceUsesGitCommand(source: SourceMode) bool {
    return switch (source) {
        .unstaged, .cached, .range, .no_index => true,
        .stdin, .pager, .patch_file => false,
    };
}

pub fn sourceIsOneShotInput(source: SourceMode) bool {
    return switch (source) {
        .stdin, .pager => true,
        .unstaged, .cached, .patch_file, .range, .no_index => false,
    };
}

pub fn sourceSupportsWatch(source: SourceMode) bool {
    return switch (source) {
        .unstaged, .cached, .range, .patch_file, .no_index => true,
        .stdin, .pager => false,
    };
}

pub fn sourceAllowsStageAction(source: SourceMode) bool {
    return switch (source) {
        .unstaged => true,
        .cached, .stdin, .pager, .patch_file, .range, .no_index => false,
    };
}

pub fn sourceAllowsUnstageAction(source: SourceMode) bool {
    return switch (source) {
        .unstaged, .cached => true,
        .stdin, .pager, .patch_file, .range, .no_index => false,
    };
}

pub fn sourceAllowsDiscardAction(source: SourceMode) bool {
    return switch (source) {
        .unstaged => true,
        .cached, .stdin, .pager, .patch_file, .range, .no_index => false,
    };
}

pub fn sourceAllowsStageProjection(source: SourceMode) bool {
    return switch (source) {
        .unstaged, .cached => true,
        .stdin, .pager, .patch_file, .range, .no_index => false,
    };
}

pub fn sourceAllowsEditorAction(source: SourceMode) bool {
    return switch (source) {
        .unstaged, .cached => true,
        .stdin, .pager, .patch_file, .range, .no_index => false,
    };
}

pub const ParseArgsError = error{
    UnknownOption,
    MissingOptionValue,
    InvalidRange,
    TooManyInputs,
    ConflictingSourceMode,
    ConflictingOutputMode,
    ConflictingWatchOverride,
    UnsupportedWatchSource,
};

pub const LoadError = git_backend.LoadError || error{
    ReadFailed,
    MissingRepoRoot,
};

pub const LoadResult = git_backend.LoadResult;

pub fn parseArgs(args: []const []const u8) ParseArgsError!CliConfig {
    var config: CliConfig = .{};
    var input_count: usize = 0;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--cached")) {
            try setSourceMode(&config, .cached);
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            try setSourceMode(&config, .stdin);
        } else if (std.mem.eql(u8, arg, "--pager")) {
            try setSourceMode(&config, .{ .pager = "" });
        } else if (std.mem.eql(u8, arg, "--difftool")) {
            if (index + 2 >= args.len) return error.MissingOptionValue;
            const left = args[index + 1];
            const right = args[index + 2];
            try setSourceMode(&config, .{ .no_index = .{ .left = left, .right = right } });
            index += 2;
        } else if (std.mem.eql(u8, arg, "--watch")) {
            if (config.auto_reload == .disabled) return error.ConflictingWatchOverride;
            config.auto_reload = .enabled;
        } else if (std.mem.eql(u8, arg, "--no-watch")) {
            if (config.auto_reload == .enabled) return error.ConflictingWatchOverride;
            config.auto_reload = .disabled;
        } else if (std.mem.eql(u8, arg, "--stats-summary")) {
            config.stats_summary = true;
        } else if (std.mem.eql(u8, arg, "--export-context")) {
            if (config.review_mode) return error.ConflictingOutputMode;
            config.export_context = true;
        } else if (std.mem.eql(u8, arg, "--review")) {
            if (config.export_context) return error.ConflictingOutputMode;
            config.review_mode = true;
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

    if (config.auto_reload == .enabled and !sourceSupportsWatch(config.source)) return error.UnsupportedWatchSource;

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
        .cached => .cached,
        .stdin => .stdin,
        .pager => |bytes| .{ .pager = try allocator.dupe(u8, bytes) },
        .patch_file => |path| .{ .patch_file = try allocator.dupe(u8, path) },
        .range => |range| .{ .range = try allocator.dupe(u8, range) },
        .no_index => |paths| .{ .no_index = try clonePathPair(allocator, paths) },
    };
}

fn clonePathPair(allocator: std.mem.Allocator, paths: PathPair) std.mem.Allocator.Error!PathPair {
    const left = try allocator.dupe(u8, paths.left);
    errdefer allocator.free(left);

    const right = try allocator.dupe(u8, paths.right);
    return .{ .left = left, .right = right };
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
        .pager => |bytes| allocator.free(bytes),
        .patch_file => |path| allocator.free(path),
        .range => |range| allocator.free(range),
        .no_index => |paths| {
            allocator.free(paths.left);
            allocator.free(paths.right);
        },
        else => {},
    }
}

pub fn freeLoadRequest(allocator: std.mem.Allocator, request: LoadRequest) void {
    freeSource(allocator, request.source);
    if (request.repo_root) |repo_root| allocator.free(repo_root);
}

/// Convenience entry point for terminal mode.
///
/// Raw sources are read locally here. Git-command sources are converted to a
/// git_backend request so the backend boundary never needs to model stdin or
/// patch-file input.
pub fn load(allocator: std.mem.Allocator, io: std.Io, request: LoadRequest) LoadError!LoadResult {
    return switch (request.source) {
        .patch_file => |path| .{ .ok = readPatchFile(allocator, io, path) catch |err| return mapReadError(err) },
        .stdin => .{ .ok = readStdin(allocator, io) catch |err| return mapReadError(err) },
        .pager => |bytes| .{ .ok = allocator.dupe(u8, bytes) catch |err| return mapReadError(err) },
        .unstaged, .cached, .range, .no_index => if (sourceUsesGitCommand(request.source)) {
            var local_backend: git_backend.LocalCommandBackend = .{};
            return local_backend.backend().loadDiff(allocator, io, try gitDiffRequest(request));
        } else unreachable,
    };
}

fn gitDiffRequest(request: LoadRequest) LoadError!git_backend.GitDiffRequest {
    return .{
        .repo_root = switch (request.source) {
            .no_index => null,
            else => request.repo_root orelse return error.MissingRepoRoot,
        },
        .kind = switch (request.source) {
            .unstaged => .unstaged,
            .cached => .cached,
            .range => |range| .{ .range = range },
            .no_index => |paths| .{ .no_index = .{ .left = paths.left, .right = paths.right } },
            .stdin, .pager, .patch_file => unreachable,
        },
    };
}

fn readPatchFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(git_backend.max_diff_bytes));
}

fn readStdin(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
    return try reader.interface.allocRemaining(allocator, .limited(git_backend.max_diff_bytes));
}

pub fn preparePagerSource(allocator: std.mem.Allocator, io: std.Io) LoadError!?SourceMode {
    const raw = readStdin(allocator, io) catch |err| return mapReadError(err);
    defer allocator.free(raw);

    const stripped = stripAnsiAlloc(allocator, raw) catch |err| return mapReadError(err);
    errdefer allocator.free(stripped);

    if (std.mem.trim(u8, stripped, " \t\r\n").len == 0) {
        allocator.free(stripped);
        return null;
    }

    return .{ .pager = stripped };
}

pub fn stripAnsiAlloc(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            const next = index + 1;
            if (next < text.len and text[next] == '[') {
                index = skipCsi(text, next + 1);
                continue;
            }
            index += 1;
            continue;
        }
        try out.append(allocator, text[index]);
        index += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn skipCsi(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte >= 0x40 and byte <= 0x7e) return index + 1;
    }
    return text.len;
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
}

test "parseArgs accepts cached mode" {
    const args = [_][]const u8{ "gitframe", "--cached" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .cached);
}

test "parseArgs accepts stdin mode" {
    const args = [_][]const u8{ "gitframe", "--stdin" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .stdin);
}

test "parseArgs accepts pager mode" {
    const args = [_][]const u8{ "gitframe", "--pager" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .pager);
    try std.testing.expectEqualStrings("", config.source.pager);
}

test "parseArgs accepts difftool mode" {
    const args = [_][]const u8{ "gitframe", "--difftool", "left.txt", "right.txt" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .no_index);
    try std.testing.expectEqualStrings("left.txt", config.source.no_index.left);
    try std.testing.expectEqualStrings("right.txt", config.source.no_index.right);
}

test "parseArgs accepts option-like difftool paths" {
    const args = [_][]const u8{ "gitframe", "--difftool", "--left", "--right" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.source == .no_index);
    try std.testing.expectEqualStrings("--left", config.source.no_index.left);
    try std.testing.expectEqualStrings("--right", config.source.no_index.right);
}

test "parseArgs rejects missing difftool paths" {
    const missing_both = [_][]const u8{ "gitframe", "--difftool" };
    try std.testing.expectError(error.MissingOptionValue, parseArgs(missing_both[0..]));

    const missing_right = [_][]const u8{ "gitframe", "--difftool", "left.txt" };
    try std.testing.expectError(error.MissingOptionValue, parseArgs(missing_right[0..]));
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

test "parseArgs accepts context export mode" {
    const args = [_][]const u8{ "gitframe", "--export-context", "--cached" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.export_context);
    try std.testing.expect(config.source == .cached);
}

test "parseArgs accepts review mode" {
    const args = [_][]const u8{ "gitframe", "--review", "--cached" };
    const config = try parseArgs(args[0..]);

    try std.testing.expect(config.review_mode);
    try std.testing.expect(config.source == .cached);
}

test "parseArgs rejects conflicting output modes" {
    const export_then_review = [_][]const u8{ "gitframe", "--export-context", "--review" };
    try std.testing.expectError(error.ConflictingOutputMode, parseArgs(export_then_review[0..]));

    const review_then_export = [_][]const u8{ "gitframe", "--review", "--export-context" };
    try std.testing.expectError(error.ConflictingOutputMode, parseArgs(review_then_export[0..]));
}

test "parseArgs rejects watch with stdin" {
    const args = [_][]const u8{ "gitframe", "--stdin", "--watch" };
    try std.testing.expectError(error.UnsupportedWatchSource, parseArgs(args[0..]));
}

test "parseArgs rejects watch with pager" {
    const args = [_][]const u8{ "gitframe", "--pager", "--watch" };
    try std.testing.expectError(error.UnsupportedWatchSource, parseArgs(args[0..]));
}

test "parseArgs allows inherited and explicitly disabled auto reload for one-shot sources" {
    const inherited_args = [_][]const u8{ "gitframe", "--stdin" };
    const inherited = try parseArgs(inherited_args[0..]);
    try std.testing.expectEqual(AutoReloadOverride.inherit, inherited.auto_reload);

    const disabled_args = [_][]const u8{ "gitframe", "--stdin", "--no-watch" };
    const disabled = try parseArgs(disabled_args[0..]);
    try std.testing.expectEqual(AutoReloadOverride.disabled, disabled.auto_reload);
}

test "parseArgs accepts watch with difftool" {
    const args = [_][]const u8{ "gitframe", "--watch", "--difftool", "left.txt", "right.txt" };
    const config = try parseArgs(args[0..]);
    try std.testing.expect(config.source == .no_index);
    try std.testing.expectEqual(AutoReloadOverride.enabled, config.auto_reload);

    const trailing = [_][]const u8{ "gitframe", "--difftool", "left.txt", "right.txt", "--watch" };
    const trailing_config = try parseArgs(trailing[0..]);
    try std.testing.expect(trailing_config.source == .no_index);
    try std.testing.expectEqual(AutoReloadOverride.enabled, trailing_config.auto_reload);
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
    const stdin_and_file = [_][]const u8{ "gitframe", "--stdin", "change.diff" };
    try std.testing.expectError(error.ConflictingSourceMode, parseArgs(stdin_and_file[0..]));

    const stdin_and_pager = [_][]const u8{ "gitframe", "--stdin", "--pager" };
    try std.testing.expectError(error.ConflictingSourceMode, parseArgs(stdin_and_pager[0..]));

    const cached_and_difftool = [_][]const u8{ "gitframe", "--cached", "--difftool", "left", "right" };
    try std.testing.expectError(error.ConflictingSourceMode, parseArgs(cached_and_difftool[0..]));

    const cached_and_range = [_][]const u8{ "gitframe", "--cached", "--range", "main...HEAD" };
    try std.testing.expectError(error.ConflictingSourceMode, parseArgs(cached_and_range[0..]));

    const range_and_stdin = [_][]const u8{ "gitframe", "--range=main...HEAD", "--stdin" };
    try std.testing.expectError(error.ConflictingSourceMode, parseArgs(range_and_stdin[0..]));
}

test "cloneSource duplicates payload source modes" {
    const allocator = std.testing.allocator;
    const source = try cloneSource(allocator, .{ .range = "main...HEAD" });
    defer freeSource(allocator, source);

    try std.testing.expect(source == .range);
    try std.testing.expectEqualStrings("main...HEAD", source.range);
}

test "cloneSource duplicates pager payload" {
    const allocator = std.testing.allocator;
    const source = try cloneSource(allocator, .{ .pager = "diff --git a/a b/a\n" });
    defer freeSource(allocator, source);

    try std.testing.expect(source == .pager);
    try std.testing.expectEqualStrings("diff --git a/a b/a\n", source.pager);
}

test "cloneSource duplicates difftool paths" {
    const allocator = std.testing.allocator;
    const source = try cloneSource(allocator, .{ .no_index = .{ .left = "left.txt", .right = "right.txt" } });
    defer freeSource(allocator, source);

    try std.testing.expect(source == .no_index);
    try std.testing.expectEqualStrings("left.txt", source.no_index.left);
    try std.testing.expectEqualStrings("right.txt", source.no_index.right);
}

test "LoadRequest identifies sources that require a repo root" {
    try std.testing.expect((LoadRequest{ .source = .unstaged }).requiresRepo());
    try std.testing.expect((LoadRequest{ .source = .cached }).requiresRepo());
    try std.testing.expect((LoadRequest{ .source = .{ .range = "main...HEAD" } }).requiresRepo());

    try std.testing.expect(!(LoadRequest{ .source = .stdin }).requiresRepo());
    try std.testing.expect(!(LoadRequest{ .source = .{ .pager = "diff" } }).requiresRepo());
    try std.testing.expect(!(LoadRequest{ .source = .{ .patch_file = "change.diff" } }).requiresRepo());
    try std.testing.expect(!(LoadRequest{ .source = .{ .no_index = .{ .left = "left", .right = "right" } } }).requiresRepo());
}

test "sourceUsesGitCommand separates command and raw sources" {
    try std.testing.expect(sourceUsesGitCommand(.unstaged));
    try std.testing.expect(sourceUsesGitCommand(.cached));
    try std.testing.expect(sourceUsesGitCommand(.{ .range = "main...HEAD" }));
    try std.testing.expect(sourceUsesGitCommand(.{ .no_index = .{ .left = "left", .right = "right" } }));
    try std.testing.expect(!sourceUsesGitCommand(.stdin));
    try std.testing.expect(!sourceUsesGitCommand(.{ .pager = "diff" }));
    try std.testing.expect(!sourceUsesGitCommand(.{ .patch_file = "change.diff" }));
}

test "sourceIsOneShotInput identifies stdin and pager" {
    try std.testing.expect(sourceIsOneShotInput(.stdin));
    try std.testing.expect(sourceIsOneShotInput(.{ .pager = "diff" }));
    try std.testing.expect(!sourceIsOneShotInput(.unstaged));
    try std.testing.expect(!sourceIsOneShotInput(.cached));
    try std.testing.expect(!sourceIsOneShotInput(.{ .range = "main...HEAD" }));
    try std.testing.expect(!sourceIsOneShotInput(.{ .patch_file = "change.diff" }));
    try std.testing.expect(!sourceIsOneShotInput(.{ .no_index = .{ .left = "left", .right = "right" } }));
}

test "sourceSupportsWatch rejects only one-shot sources" {
    try std.testing.expect(sourceSupportsWatch(.unstaged));
    try std.testing.expect(sourceSupportsWatch(.cached));
    try std.testing.expect(sourceSupportsWatch(.{ .range = "main...HEAD" }));
    try std.testing.expect(sourceSupportsWatch(.{ .patch_file = "change.diff" }));
    try std.testing.expect(!sourceSupportsWatch(.stdin));
    try std.testing.expect(!sourceSupportsWatch(.{ .pager = "diff" }));
    try std.testing.expect(sourceSupportsWatch(.{ .no_index = .{ .left = "left", .right = "right" } }));
}

test "stage action is narrower than stage projection" {
    try std.testing.expect(sourceAllowsStageAction(.unstaged));
    try std.testing.expect(!sourceAllowsStageAction(.cached));
    try std.testing.expect(!sourceAllowsStageAction(.{ .range = "main...HEAD" }));

    try std.testing.expect(sourceAllowsUnstageAction(.unstaged));
    try std.testing.expect(sourceAllowsUnstageAction(.cached));
    try std.testing.expect(!sourceAllowsUnstageAction(.{ .range = "main...HEAD" }));

    try std.testing.expect(sourceAllowsDiscardAction(.unstaged));
    try std.testing.expect(!sourceAllowsDiscardAction(.cached));
    try std.testing.expect(!sourceAllowsDiscardAction(.{ .range = "main...HEAD" }));

    try std.testing.expect(sourceAllowsStageProjection(.unstaged));
    try std.testing.expect(sourceAllowsStageProjection(.cached));
    try std.testing.expect(!sourceAllowsStageProjection(.{ .range = "main...HEAD" }));

    try std.testing.expect(sourceAllowsEditorAction(.unstaged));
    try std.testing.expect(sourceAllowsEditorAction(.cached));
    try std.testing.expect(!sourceAllowsEditorAction(.{ .range = "main...HEAD" }));
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
    }));
}

test "stripAnsiAlloc removes common CSI color sequences" {
    const allocator = std.testing.allocator;
    const stripped = try stripAnsiAlloc(allocator, "\x1b[31mdiff --git a/a b/a\x1b[0m\n\x1b[m");
    defer allocator.free(stripped);

    try std.testing.expectEqualStrings("diff --git a/a b/a\n", stripped);
}

test "stripAnsiAlloc removes multi-parameter CSI sequences" {
    const allocator = std.testing.allocator;
    const stripped = try stripAnsiAlloc(allocator, "\x1b[1;32m+added\x1b[39;49m");
    defer allocator.free(stripped);

    try std.testing.expectEqualStrings("+added", stripped);
}

test "stripAnsiAlloc drops incomplete escape sequences safely" {
    const allocator = std.testing.allocator;
    const stripped = try stripAnsiAlloc(allocator, "line\n\x1b[31");
    defer allocator.free(stripped);

    try std.testing.expectEqualStrings("line\n", stripped);
}
