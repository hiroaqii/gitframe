/// App-local Git operation target classification.
///
/// This module describes what the current UI selection resolved to before a
/// concrete async task is started. Concrete git command execution remains in
/// app/actions.zig.
pub const TargetKind = enum {
    file,
    directory,
};

pub const PathTarget = struct {
    path: []const u8,
    kind: TargetKind,
};

pub const ToggleStageOperation = enum {
    stage,
    unstage,
};

pub const StageTarget = struct {
    repo_root: []const u8,
    path: []const u8,
    kind: TargetKind,
};

pub const StageTargetResult = union(enum) {
    ready: StageTarget,
    already_staged: []const u8,
    stale_status,
    conflict_unsupported: []const u8,
    no_stageable_content: []const u8,
    unavailable_source,
    no_repo,
    no_path,
};

pub const ToggleStageTargetResult = union(enum) {
    operation: ToggleStageOperation,
    unavailable_source,
    no_repo,
    no_path,
    stale_status,
    conflict_unsupported: PathTarget,
    no_content: PathTarget,
};

pub const HunkMarkSource = enum {
    session,
    projection,
};

pub const HunkStageTarget = struct {
    repo_root: []const u8,
    path: []const u8,
    hunk_index: usize,
    /// Owned patch text returned by target resolution and transferred to the
    /// async task when the request is started.
    patch: []u8,
    mark_source: HunkMarkSource = .session,
    reload_after_success: bool = false,
};

pub const HunkStageTargetResult = union(enum) {
    ready: HunkStageTarget,
    unavailable_source,
    no_repo,
    no_file,
    no_path,
    no_hunk,
    offscreen_cursor,
    stale_status,
    conflict_unsupported,
    binary_unsupported,
    unsupported_file_state,
    already_staged_hunk,
    patch_failed,
};

pub const HunkUnstageTarget = HunkStageTarget;

pub const HunkUnstageTargetResult = union(enum) {
    ready: HunkUnstageTarget,
    unavailable_source,
    no_repo,
    no_file,
    no_path,
    no_hunk,
    offscreen_cursor,
    not_staged_hunk,
    binary_unsupported,
    unsupported_file_state,
    patch_failed,
};

pub const ToggleHunkTargetResult = union(enum) {
    operation: ToggleStageOperation,
    unavailable_source,
    no_repo,
    no_file,
    no_path,
    no_hunk,
    offscreen_cursor,
};

pub const UnstageTarget = struct {
    repo_root: []const u8,
    path: []const u8,
    kind: TargetKind,
};

pub const UnstageTargetResult = union(enum) {
    ready: UnstageTarget,
    unavailable_source,
    no_repo,
    no_path,
    stale_status,
    conflict_unsupported: PathTarget,
    no_staged_content: PathTarget,
};

pub const DiscardTarget = struct {
    repo_root: []const u8,
    path: []const u8,
};

pub const DiscardTargetResult = union(enum) {
    ready: DiscardTarget,
    unavailable_source,
    no_repo,
    no_path,
    stale_status,
    directory_unsupported,
    conflict_unsupported,
    untracked_unsupported,
    no_unstaged_content,
};
