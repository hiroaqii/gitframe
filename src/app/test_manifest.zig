//! Compiler-consumed manifest for tests that exercise the App surface.
//! Keep this file free of test blocks; `include` is called by the package root.

pub fn include() void {
    _ = @import("../app.zig");
    _ = @import("../app_test.zig");
    _ = @import("effect_origin.zig");
    _ = @import("initial_selection.zig");
    _ = @import("load_test.zig");
    _ = @import("message.zig");
    _ = @import("shell_effects_test.zig");
    _ = @import("repo_session.zig");
    _ = @import("workflow/action_lifecycle_test.zig");
    _ = @import("workflow/local_test.zig");
    _ = @import("workflow/remote_test.zig");
    _ = @import("page_coordinator_test.zig");
    _ = @import("pages/repository/coordinator_test.zig");
    _ = @import("pages/changes/content_app_test.zig");
    _ = @import("pages/changes/navigation_app_test.zig");
    _ = @import("pages/changes/read_coordinator_test.zig");
    _ = @import("tests/page_transition.zig");
    _ = @import("tests/canonical_publication.zig");
    _ = @import("tests/local_workflow.zig");
    _ = @import("tests/remote_shell.zig");
    _ = @import("tests/root_shell.zig");
    _ = @import("tests/root_view.zig");
    _ = @import("tests/update_tail.zig");
}
