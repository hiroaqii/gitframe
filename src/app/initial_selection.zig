//! Initial and current selection context construction.
//!
//! This module owns the process-facing context export path and the pure mapping
//! from loaded diff/status models into neutral selection data. It has no access
//! to application state; the root shell supplies the current repository and
//! selection snapshots.

const std = @import("std");

const app_load = @import("load.zig");
const context = @import("../context.zig");
const context_export = @import("../context_export.zig");
const diff_file = @import("../diff/file.zig");
const diff_source = @import("../diff/source.zig");
const git_status = @import("../git/status.zig");
const loaded_diff = @import("../loaded_diff.zig");
const repo_discovery = @import("../repo/discovery.zig");

const LoadedDiff = loaded_diff.LoadedDiff;
const SourceMode = diff_source.SourceMode;
const CliConfig = diff_source.CliConfig;

pub fn exportContextJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: CliConfig,
    writer: *std.Io.Writer,
) !void {
    var discovery: ?repo_discovery.DiscoveryResult = null;
    defer if (discovery) |*result| result.deinit(allocator);

    const repo_root = if (diff_source.sourceRequiresRepo(config.source)) blk: {
        discovery = try repo_discovery.discover(allocator, io);
        const discovered_root = try activeRootFromDiscovery(discovery.?);
        break :blk discovered_root orelse return error.MissingRepoRoot;
    } else null;

    var load_result = app_load.runLoad(.{
        .source = config.source,
        .repo_root = repo_root,
    }, allocator, io);
    defer load_result.deinit(allocator);

    var status_result: ?app_load.StatusLoadTaskResult = null;
    defer if (status_result) |*result| result.deinit(allocator);

    const selection = switch (load_result) {
        .unchanged => unreachable,
        .empty => blk: {
            status_result = initialStatusLoadResultIfNeeded(config.source, repo_root, allocator, io);
            break :blk initialContext(
                config.source,
                repo_root,
                null,
                initialStatusDocument(optionalStatusResultPtr(&status_result)),
            );
        },
        .loaded => |*bundle| blk: {
            const loaded_selection = initialSelection(&bundle.loaded);
            if (loaded_selection != null) {
                break :blk contextForSelection(config.source, repo_root, loaded_selection);
            }
            status_result = initialStatusLoadResultIfNeeded(config.source, repo_root, allocator, io);
            break :blk initialContext(
                config.source,
                repo_root,
                &bundle.loaded,
                initialStatusDocument(optionalStatusResultPtr(&status_result)),
            );
        },
        .failed, .failed_static => return error.ExportContextLoadFailed,
    };

    try context_export.writeSelectionContext(writer, selection);
}

pub fn contextForSelection(
    source: SourceMode,
    repo_root: ?[]const u8,
    selected: ?context.Selection,
) context.SelectionContext {
    return .{
        .repo_root = repo_root,
        .source = sourceContext(source),
        .selected = selected,
    };
}

fn initialContext(
    source: SourceMode,
    repo_root: ?[]const u8,
    loaded: ?*const LoadedDiff,
    status: ?git_status.StatusDocument,
) context.SelectionContext {
    const selected = if (loaded) |active_loaded|
        initialSelection(active_loaded) orelse initialStatusOnlySelection(status)
    else
        initialStatusOnlySelection(status);
    return contextForSelection(source, repo_root, selected);
}

fn sourceContext(source: SourceMode) context.SourceContext {
    // Labels intentionally mirror CliConfig.sourceLabel(); this is the
    // boundary where CLI source modes become neutral context data.
    return switch (source) {
        .unstaged => .{ .kind = .unstaged, .label = "unstaged changes" },
        .cached => .{ .kind = .cached, .label = "staged changes" },
        .stdin => .{ .kind = .stdin, .label = "stdin diff" },
        .pager => .{ .kind = .pager, .label = "pager diff" },
        .patch_file => |path| .{ .kind = .patch_file, .label = "patch file", .detail = path },
        .range => |range| .{ .kind = .range, .label = "range", .detail = range },
        .no_index => |paths| .{
            .kind = .no_index,
            .label = "difftool",
            .left_path = paths.left,
            .right_path = paths.right,
        },
    };
}

fn activeRootFromDiscovery(result: repo_discovery.DiscoveryResult) !?[]const u8 {
    return switch (result) {
        .single_repo => |entry| entry.canonical_root,
        .workspace => error.AmbiguousWorkspaceExport,
        .none => null,
    };
}

fn initialStatusLoadResultIfNeeded(
    source: SourceMode,
    repo_root: ?[]const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
) ?app_load.StatusLoadTaskResult {
    if (!diff_source.sourceRequiresRepo(source)) return null;
    const root = repo_root orelse return null;
    return app_load.runStatusLoad(root, allocator, io);
}

fn optionalStatusResultPtr(
    result: *?app_load.StatusLoadTaskResult,
) ?*app_load.StatusLoadTaskResult {
    if (result.*) |*value| return value;
    return null;
}

fn initialStatusDocument(
    result: ?*app_load.StatusLoadTaskResult,
) ?git_status.StatusDocument {
    const status = result orelse return null;
    return switch (status.*) {
        .loaded => |bundle| bundle.document,
        .empty, .failed, .failed_static => null,
    };
}

fn initialSelection(loaded: *const LoadedDiff) ?context.Selection {
    if (loaded.document.files.len == 0) return null;
    const file = loaded.document.files[0];
    return .{ .diff_file = .{
        .file_index = 0,
        .display_path = diff_file.displayPath(file),
        .path_key = diff_file.canonicalPathKey(file),
        .hunk_index = if (file.hunks.len > 0) 0 else null,
    } };
}

fn initialStatusOnlySelection(
    status: ?git_status.StatusDocument,
) ?context.Selection {
    const document = status orelse return null;
    for (document.entries, 0..) |entry, status_index| {
        if (entry.isIgnored()) continue;
        const path_key = entry.canonicalPathKey() orelse continue;
        // status_index is advisory; path_key is the stable identity.
        return .{ .status_only = .{
            .status_index = status_index,
            .path_key = path_key,
        } };
    }
    return null;
}

const app_test_support = @import("test_support.zig");

test "initialSelectionContext selects first diff file and hunk" {
    const loaded = app_test_support.loadedDiffTwo();
    const selection = initialContext(.{ .patch_file = "changes.diff" }, null, &loaded, null);

    try std.testing.expect(selection.repo_root == null);
    try std.testing.expectEqual(context.SourceKind.patch_file, selection.source.kind);
    try std.testing.expectEqualStrings("changes.diff", selection.source.detail.?);

    const file = selection.selected.?.diff_file;
    try std.testing.expectEqual(@as(usize, 0), file.file_index);
    try std.testing.expectEqualStrings("a", file.path_key.?);
    try std.testing.expectEqual(@as(?usize, 0), file.hunk_index);
}

test "initialSelectionContext prefers diff file before status-only selection" {
    const loaded = app_test_support.loadedDiffTwo();
    const doc = try git_status.parse(std.testing.allocator, "?? src/status-only.zig\x00");
    defer std.testing.allocator.free(doc.entries);

    const selection = initialContext(.unstaged, "/repo", &loaded, doc);

    const file = selection.selected.?.diff_file;
    try std.testing.expectEqual(@as(usize, 0), file.file_index);
    try std.testing.expectEqualStrings("a", file.path_key.?);
}

test "initialSelectionContext falls back to first selectable status entry" {
    const empty_loaded: LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &.{} },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
    const doc = try git_status.parse(std.testing.allocator, "!! ignored.tmp\x00?? src/new.zig\x00 M src/changed.zig\x00");
    defer std.testing.allocator.free(doc.entries);

    const selection = initialContext(.unstaged, "/repo", &empty_loaded, doc);

    const status = selection.selected.?.status_only;
    try std.testing.expectEqual(@as(usize, 1), status.status_index);
    try std.testing.expectEqualStrings("src/new.zig", status.path_key.?);
}

test "initialSelectionContext returns null when diff and status have no selectable entry" {
    const empty_loaded: LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &.{} },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
    const doc = try git_status.parse(std.testing.allocator, "!! ignored.tmp\x00");
    defer std.testing.allocator.free(doc.entries);

    const selection = initialContext(.unstaged, "/repo", &empty_loaded, doc);

    try std.testing.expect(selection.selected == null);
}

test "activeRootFromDiscovery rejects ambiguous workspace export" {
    var repos = [_]repo_discovery.RepoEntry{
        .{ .label = "one", .display_path = "one", .canonical_root = "/work/one" },
        .{ .label = "two", .display_path = "two", .canonical_root = "/work/two" },
    };

    try std.testing.expectError(error.AmbiguousWorkspaceExport, activeRootFromDiscovery(.{ .workspace = .{
        .current_root = "/work",
        .repos = &repos,
    } }));
}
