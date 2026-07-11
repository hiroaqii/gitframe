const app = @import("app.zig");
pub const config = @import("config.zig");
pub const context = @import("context.zig");
pub const keymap = @import("keymap");
pub const repo_state = @import("repo/state.zig");
pub const review_session = @import("review/session.zig");
pub const theme = @import("theme");
const diff_source = @import("diff/source.zig");

pub const App = app.App;
pub const exportInitialSelectionContextJson = app.App.exportInitialSelectionContextJson;

pub const SourceMode = diff_source.SourceMode;
pub const CliConfig = diff_source.CliConfig;
pub const LoadRequest = diff_source.LoadRequest;
pub const ParseArgsError = diff_source.ParseArgsError;
pub const parseArgs = diff_source.parseArgs;
pub const freeSource = diff_source.freeSource;
pub const preparePagerSource = diff_source.preparePagerSource;

test {
    // Keep package-root-owned test modules directly reachable from this block.
    // Plain file-scope imports are insufficient for named-test discovery when
    // Zig's --test-filter is active.
    // Modules with dedicated test artifacts are discovered by those roots instead.
    _ = @import("app.zig");
    _ = @import("app/test_support.zig");
    _ = @import("app_test.zig");
    _ = @import("app/actions.zig");
    _ = @import("app/auto_reload.zig");
    _ = @import("app/commit_panel.zig");
    _ = @import("app/git_requests.zig");
    _ = @import("app/git_ops.zig");
    _ = @import("app/input.zig");
    _ = @import("app/load.zig");
    _ = @import("app/load_state.zig");
    _ = @import("app/pages/review.zig");
    _ = @import("app/pages/review/navigation.zig");
    _ = @import("app/pages/review/authority.zig");
    _ = @import("app/pages/review/operations.zig");
    _ = @import("app/pages/review/reload.zig");
    _ = @import("app/prompt.zig");
    _ = @import("app/repo_picker.zig");
    _ = @import("app/review_projection.zig");
    _ = @import("app/state.zig");
    _ = @import("app/text_buffer.zig");
    _ = @import("app/text_edit.zig");
    _ = @import("app/view.zig");
    _ = @import("config.zig");
    _ = @import("context.zig");
    _ = @import("context_export.zig");
    _ = @import("draw");
    _ = @import("diff/file.zig");
    _ = @import("diff/hunk_projection.zig");
    _ = @import("diff/patch.zig");
    _ = @import("diff/render.zig");
    _ = @import("diff/selection.zig");
    _ = @import("diff/syntax.zig");
    _ = @import("editor.zig");
    _ = @import("external/action.zig");
    _ = @import("git/backend.zig");
    _ = @import("git/branch_status.zig");
    _ = @import("git/status.zig");
    _ = @import("keymap");
    _ = @import("loaded_diff.zig");
    _ = @import("path_key.zig");
    _ = @import("process/runner.zig");
    _ = @import("repo/state.zig");
    _ = @import("review/session.zig");
    _ = @import("review/state.zig");
    _ = @import("syntax/provider.zig");
    _ = @import("syntax/provider_none.zig");
    _ = @import("syntax/provider_runtime.zig");
    _ = @import("theme");
}
