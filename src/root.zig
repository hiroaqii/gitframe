const app = @import("app.zig");
const diff_source = @import("diff_source.zig");

pub const App = app.App;

pub const SourceMode = diff_source.SourceMode;
pub const CliConfig = diff_source.CliConfig;
pub const LoadRequest = diff_source.LoadRequest;
pub const ParseArgsError = diff_source.ParseArgsError;
pub const parseArgs = diff_source.parseArgs;

test {
    // Keep app.zig's top-level tests in the package test target while root.zig
    // stays a thin facade.
    _ = @import("app.zig");
}
