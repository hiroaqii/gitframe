const std = @import("std");

/// Diff source class exposed to external integrations.
///
/// This deliberately mirrors the user-visible source modes without importing
/// the CLI module, keeping context export usable from tests and browser-facing
/// code that do not need terminal argument parsing.
pub const SourceKind = enum {
    unstaged,
    cached,
    stdin,
    pager,
    patch_file,
    range,
    no_index,
};

/// Borrowed description of the active source.
///
/// `label` is short and display-oriented. `detail` is optional source-specific
/// context such as a range string or patch path.
pub const SourceContext = struct {
    kind: SourceKind,
    label: []const u8,
    detail: ?[]const u8 = null,
    left_path: ?[]const u8 = null,
    right_path: ?[]const u8 = null,
};

/// Canonical repo-relative path used to connect diff files, status entries,
/// review state, and sidebar targets.
///
/// The slice is borrowed from the source document. Async payloads or persistent
/// stores must duplicate the key before keeping it beyond the active load.
pub const PathKey = []const u8;

/// Sidebar row identity.
///
/// Directories are cursor targets only. File and status rows can become action
/// targets, but their indexes are valid only for the active loaded/status
/// generation.
pub const SidebarTarget = union(enum) {
    directory: PathKey,
    diff_file: usize,
    status_entry: usize,

    /// Transitional compatibility for code that still consumes diff file rows.
    /// TODO(phase8): remove once status-only sidebar rows have first-class
    /// action handling and callers switch to target-specific accessors.
    pub fn diffFileIndex(self: SidebarTarget) ?usize {
        return switch (self) {
            .diff_file => |index| index,
            else => null,
        };
    }
};

/// Action target shown in the main pane.
///
/// This is intentionally separate from the sidebar cursor: selecting a
/// directory may move the sidebar row while keeping the previous diff file
/// visible and actionable.
pub const SelectedTarget = union(enum) {
    diff_file: usize,
    status_only: usize,

    /// Transitional compatibility for diff-only panes.
    /// TODO(phase8): remove when action handlers cover status-only targets.
    pub fn diffFileIndex(self: SelectedTarget) ?usize {
        return switch (self) {
            .diff_file => |index| index,
            else => null,
        };
    }
};

/// Model-coordinate selection for a diff file.
///
/// Hunk index is optional because empty/binary/status-only bodies can have no
/// hunk to identify. Rendered row offsets intentionally do not appear here.
pub const DiffFileSelection = struct {
    file_index: usize,
    display_path: []const u8,
    path_key: ?PathKey = null,
    hunk_index: ?usize = null,
};

/// Placeholder for a status-only sidebar row.
///
/// The type exists before status-only rows are rendered so action/export code
/// can be written against the final target shape.
pub const StatusOnlySelection = struct {
    status_index: usize,
    path_key: ?PathKey = null,
};

pub const Selection = union(enum) {
    diff_file: DiffFileSelection,
    status_only: StatusOnlySelection,
};

/// External-action context for the current app selection.
///
/// The slices are borrowed from the active app state / loaded diff. Clone this
/// context before sending it to async work.
pub const SelectionContext = struct {
    repo_root: ?[]const u8,
    source: SourceContext,
    selected: ?Selection,
};

/// Normalize a git path to a repo-relative key.
///
/// Removes `a/` and `b/` side prefixes and excludes `/dev/null`, which is a
/// diff endpoint rather than a repository path.
/// `diff/file.zig` and `git/status.zig` intentionally duplicate this rule today
/// because they are tested as standalone roots.
pub fn canonicalRepoPath(path: []const u8) ?PathKey {
    if (isDevNull(path)) return null;
    const stripped = stripGitSidePrefix(path);
    if (isDevNull(stripped) or stripped.len == 0) return null;
    return stripped;
}

pub fn stripGitSidePrefix(path: []const u8) []const u8 {
    if (path.len >= 2 and (path[0] == 'a' or path[0] == 'b') and path[1] == '/') return path[2..];
    return path;
}

fn isDevNull(path: []const u8) bool {
    return std.mem.eql(u8, path, "/dev/null");
}

test "canonical repo path strips git side prefixes" {
    try std.testing.expectEqualStrings("src/main.zig", canonicalRepoPath("a/src/main.zig").?);
    try std.testing.expectEqualStrings("src/main.zig", canonicalRepoPath("b/src/main.zig").?);
    try std.testing.expectEqualStrings("src/main.zig", canonicalRepoPath("src/main.zig").?);
}

test "canonical repo path excludes dev null" {
    try std.testing.expect(canonicalRepoPath("/dev/null") == null);
}
