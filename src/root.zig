const app = @import("app.zig");
const build_options = @import("build_options");
pub const config = @import("config.zig");
pub const keymap = @import("keymap");
pub const repo_state = @import("repo/state.zig");
pub const review_session = @import("review/session.zig");
pub const theme = @import("theme");
const diff_source = @import("diff/source.zig");

pub const App = app.App;
pub const exportInitialSelectionContextJson = app.App.exportInitialSelectionContextJson;

pub const CliConfig = diff_source.CliConfig;
pub const ParseArgsError = diff_source.ParseArgsError;
pub const parseArgs = diff_source.parseArgs;
pub const freeSource = diff_source.freeSource;
pub const preparePagerSource = diff_source.preparePagerSource;

test {
    @import("app/test_manifest.zig").include();
    if (build_options.expected_package_root_test_count != 0) {
        try @import("std").testing.expectEqual(
            build_options.expected_package_root_test_count,
            @import("builtin").test_functions.len,
        );
    }
    // Keep package-root-owned test modules directly reachable from this block.
    // Plain file-scope imports are insufficient for named-test discovery when
    // Zig's --test-filter is active.
    // Modules with dedicated test artifacts are discovered by those roots instead.
    _ = @import("app/test_support.zig");
    _ = @import("git/repository_change.zig");
    _ = @import("app/actions.zig");
    _ = @import("app/auto_reload.zig");
    _ = @import("app/branch_chrome.zig");
    _ = @import("app/commit_panel.zig");
    _ = @import("app/cursor_viewport.zig");
    _ = @import("app/diff_surface/body_resolver.zig");
    _ = @import("app/git_requests.zig");
    _ = @import("app/git_ops.zig");
    _ = @import("app/input.zig");
    _ = @import("app/key_input.zig");
    _ = @import("app/load.zig");
    _ = @import("app/load_state.zig");
    _ = @import("app/page.zig");
    _ = @import("app/page_link.zig");
    _ = @import("app/page_transition.zig");
    _ = @import("app/projection_component.zig");
    _ = @import("app/shell_layout.zig");
    _ = @import("app/pages/review.zig");
    _ = @import("app/pages/review/content.zig");
    _ = @import("app/pages/review/input.zig");
    _ = @import("app/pages/review/layout.zig");
    _ = @import("app/pages/review/message.zig");
    _ = @import("app/pages/review/navigation.zig");
    _ = @import("app/diff_surface/authority.zig");
    _ = @import("app/pages/review/repository_read_authority.zig");
    _ = @import("app/pages/review/operations.zig");
    _ = @import("app/pages/review/reload.zig");
    _ = @import("app/pages/review/update.zig");
    _ = @import("app/pages/review/view.zig");
    _ = @import("app/pages/repository.zig");
    _ = @import("app/pages/repository/branch.zig");
    _ = @import("app/pages/repository/path_history.zig");
    _ = @import("app/pages/repository/file_search_focus.zig");
    _ = @import("app/pages/repository/input.zig");
    _ = @import("app/pages/repository/model.zig");
    _ = @import("app/pages/repository/navigation.zig");
    _ = @import("app/pages/repository/selection.zig");
    _ = @import("app/pages/repository/source_header.zig");
    _ = @import("app/pages/repository/source_geometry.zig");
    _ = @import("app/pages/repository/tasks.zig");
    _ = @import("app/pages/repository/tree_projection.zig");
    _ = @import("app/pages/repository/view.zig");
    _ = @import("app/prompt.zig");
    _ = @import("app/push_retry.zig");
    _ = @import("app/repo_picker.zig");
    _ = @import("app/review_projection.zig");
    _ = @import("app/state.zig");
    _ = @import("app/text_buffer.zig");
    _ = @import("app/text_edit.zig");
    _ = @import("app/view.zig");
    _ = @import("app/view_primitives.zig");
    _ = @import("config.zig");
    _ = @import("content_fingerprint.zig");
    _ = @import("context.zig");
    _ = @import("context_export.zig");
    _ = @import("draw");
    _ = @import("diff/file.zig");
    _ = @import("diff/hunk_projection.zig");
    _ = @import("diff/patch.zig");
    _ = @import("diff/presentation_identity.zig");
    _ = @import("diff/render.zig");
    _ = @import("diff/selection.zig");
    _ = @import("diff/syntax_view.zig");
    _ = @import("editor.zig");
    _ = @import("external/action.zig");
    _ = @import("git/remote.zig");
    _ = @import("git/branch_status.zig");
    _ = @import("git/command.zig");
    _ = @import("git/compare.zig");
    _ = @import("git/operations.zig");
    _ = @import("git/read.zig");
    _ = @import("git/refs.zig");
    _ = @import("git/status.zig");
    _ = @import("keymap");
    _ = @import("loaded_diff.zig");
    _ = @import("path_key.zig");
    _ = @import("process/runner.zig");
    _ = @import("repo/state.zig");
    _ = @import("repo/root_capability.zig");
    _ = @import("repository/manifest.zig");
    _ = @import("repository/change_index.zig");
    _ = @import("repository/document.zig");
    _ = @import("repository/path.zig");
    _ = @import("repository/source.zig");
    _ = @import("repository/tree.zig");
    _ = @import("review/session.zig");
    _ = @import("review/state.zig");
    _ = @import("syntax/provider.zig");
    _ = @import("syntax/style.zig");
    _ = @import("syntax/token.zig");
    _ = @import("syntax/provider_none.zig");
    _ = @import("syntax/provider_runtime.zig");
    _ = @import("syntax/source.zig");
    _ = @import("syntax/source_none.zig");
    _ = @import("syntax/source_runtime.zig");
    _ = @import("theme");
}
