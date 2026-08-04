const std = @import("std");
const path_key = @import("path_key.zig");

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
pub const PathKey = path_key.PathKey;

/// Sidebar row identity.
///
/// Directories are cursor targets only. File and status rows can become action
/// targets, but their indexes are valid only for the active loaded/status
/// generation.
pub const SidebarTarget = union(enum) {
    repo_root,
    directory: PathKey,
    diff_file: usize,
    status_entry: usize,

    /// Transitional compatibility for code that still consumes diff file rows.
    /// TODO: remove once status-only sidebar rows have first-class action
    /// handling and callers switch to target-specific accessors.
    pub fn diffFileIndex(self: SidebarTarget) ?usize {
        return switch (self) {
            .diff_file => |index| index,
            else => null,
        };
    }
};

/// Stable sidebar row identity across tree/status/source generations.
///
/// Unlike `SidebarTarget`, this never stores generation-local file or status
/// indexes. The path slices are borrowed unless an enclosing owner explicitly
/// duplicates them.
pub const SidebarIdentity = union(enum) {
    repo_root,
    directory: PathKey,
    file: PathKey,
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
    /// TODO: remove when action handlers cover status-only targets.
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

pub const canonicalRepoPath = path_key.canonicalRepoPath;
pub const stripGitSidePrefix = path_key.stripGitSidePrefix;

test "canonical repo path strips git side prefixes" {
    try std.testing.expectEqualStrings("src/main.zig", canonicalRepoPath("a/src/main.zig").?);
    try std.testing.expectEqualStrings("src/main.zig", canonicalRepoPath("b/src/main.zig").?);
    try std.testing.expectEqualStrings("src/main.zig", canonicalRepoPath("src/main.zig").?);
}

test "canonical repo path excludes dev null" {
    try std.testing.expect(canonicalRepoPath("/dev/null") == null);
}
