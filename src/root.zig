const app = @import("app.zig");
const build_options = @import("build_options");
pub const config = @import("config.zig");
pub const ai_review = @import("ai_review.zig");
pub const committed_review = @import("committed_review.zig");
pub const review_store = @import("review_store.zig");
/// Installed process adapter for exact-target committed patch transport.
pub const review_projection_command = @import("committed_review/projection_command.zig");
/// Installed process adapter for target-only committed revision resolution.
pub const review_target_command = @import("committed_review/target_command.zig");
/// Installed process adapter for explicit Review Store binding preparation.
pub const review_store_prepare_command = @import("review_store/prepare_command.zig");
/// Installed process adapter for exact immutable Review Run publication.
pub const review_store_publish_command = @import("review_store/publish_command.zig");
/// Installed no-write adapter for exact Review Store publication identity.
pub const review_store_read_command = @import("ai_review/store_read_command.zig");
/// Installed side-effect-free AI review capability handshake.
pub const review_capabilities_command = @import("ai_review/capabilities_command.zig");
/// Installed side-effect-free deterministic review input materializer.
pub const review_input_command = @import("ai_review/input_command.zig");
/// Installed read-only adapter for canonical AI review artifact construction.
pub const review_producer_command = @import("ai_review/producer_command.zig");
pub const keymap = @import("keymap");
pub const repo_state = @import("repo/state.zig");
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
    _ = @import("app/branch_commit_time.zig");
    _ = @import("app/commit_panel.zig");
    _ = @import("app/cursor_viewport.zig");
    _ = @import("app/diff_surface/body_resolver.zig");
    _ = @import("app/git_requests.zig");
    _ = @import("app/git_ops.zig");
    _ = @import("app/input.zig");
    _ = @import("app/key_input.zig");
    _ = @import("app/load.zig");
    _ = @import("app/load_state.zig");
    _ = @import("app/review_store_operations.zig");
    _ = @import("app/page.zig");
    _ = @import("app/page_header.zig");
    _ = @import("app/page_link.zig");
    _ = @import("app/page_transition.zig");
    _ = @import("app/projection_component.zig");
    _ = @import("app/shell_layout.zig");
    _ = @import("app/pages/changes.zig");
    _ = @import("app/pages/changes/content.zig");
    _ = @import("app/pages/changes/input.zig");
    _ = @import("app/pages/changes/layout.zig");
    _ = @import("app/pages/changes/message.zig");
    _ = @import("app/pages/changes/navigation.zig");
    _ = @import("app/diff_surface/authority.zig");
    _ = @import("app/pages/changes/repository_read_authority.zig");
    _ = @import("app/pages/changes/operations.zig");
    _ = @import("app/pages/changes/reload.zig");
    _ = @import("app/pages/changes/update.zig");
    _ = @import("app/pages/changes/view.zig");
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
    _ = @import("app/changes_projection.zig");
    _ = @import("app/selection_input.zig");
    _ = @import("app/state.zig");
    _ = @import("app/text_buffer.zig");
    _ = @import("app/text_edit.zig");
    _ = @import("app/view.zig");
    _ = @import("app/view_primitives.zig");
    _ = @import("config.zig");
    _ = @import("ai_review.zig");
    _ = @import("ai_review/capabilities_command.zig");
    _ = @import("ai_review/input_command.zig");
    _ = @import("ai_review/producer_command.zig");
    _ = @import("ai_review/store_service.zig");
    _ = @import("ai_review/store_read_command.zig");
    _ = @import("content_fingerprint.zig");
    _ = @import("committed_review.zig");
    _ = @import("review_store.zig");
    _ = @import("committed_review/projection_command.zig");
    _ = @import("committed_review/target_command.zig");
    _ = @import("review_store/prepare_command.zig");
    _ = @import("review_store/publish_command.zig");
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
    _ = @import("fs/capability.zig");
    _ = @import("fs/durable.zig");
    _ = @import("git/remote.zig");
    _ = @import("git/branch_status.zig");
    _ = @import("git/command.zig");
    _ = @import("git/committed_review.zig");
    _ = @import("git/committed_review/instructions.zig");
    _ = @import("git/compare.zig");
    _ = @import("git/operations.zig");
    _ = @import("git/read.zig");
    _ = @import("git/repository_locator.zig");
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
    _ = @import("reviewed_files.zig");
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
