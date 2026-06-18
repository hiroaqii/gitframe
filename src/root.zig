const app = @import("app.zig");
const diff_source = @import("diff/source.zig");

pub const App = app.App;

pub const SourceMode = diff_source.SourceMode;
pub const CliConfig = diff_source.CliConfig;
pub const LoadRequest = diff_source.LoadRequest;
pub const ParseArgsError = diff_source.ParseArgsError;
pub const parseArgs = diff_source.parseArgs;

test {
    // Keep module-local tests in the package test target while root.zig stays a
    // thin facade. Add extracted modules here when they start owning tests.
    _ = @import("app.zig");
    _ = @import("app/input.zig");
    _ = @import("app/prompt.zig");
    _ = @import("app/view.zig");
    _ = @import("editor.zig");
    _ = @import("git/backend.zig");
    _ = @import("git/status.zig");
    _ = @import("repo/state.zig");
    _ = @import("review/state.zig");
}
