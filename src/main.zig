const std = @import("std");
const gitframe = @import("gitframe");
const chasen = @import("chasen");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (wantsHelp(args)) {
        try printHelp(init.io);
        return;
    }

    const config = gitframe.parseArgs(args) catch |err| {
        try printCliError(init.io, err);
        return err;
    };
    if (config.version) {
        try printVersion(init.io);
        return;
    }

    var config_paths = try gitframe.config.resolvePaths(init.gpa, init.environ_map);
    defer config_paths.deinit(init.gpa);
    var user_config_result = gitframe.config.loadConfig(init.gpa, init.io, config_paths.config);
    defer user_config_result.deinit();
    var config_stderr_buffer: [512]u8 = undefined;
    const user_config = try configForStartupFile(
        &user_config_result,
        config_paths.config,
        .stderr(),
        init.io,
        &config_stderr_buffer,
    );
    var app_state = gitframe.config.loadState(init.gpa, init.io, config_paths.state);
    defer app_state.deinit();
    var recent_repos: gitframe.repo_state.RecentStore = .{};
    errdefer recent_repos.deinit(init.gpa);
    try recent_repos.loadFromRecentState(init.gpa, app_state.state.value.recent_repositories);

    const palette = gitframe.theme.Palette.fromConfig(user_config.theme);
    const effective_keymap = gitframe.keymap.Effective.fromConfig(user_config.keymap);
    const executable_path = std.process.executablePathAlloc(init.io, arena) catch null;

    if (config.stats_summary) {
        var summary: StatsSummary = .{};
        const app_recent_repos = recent_repos;
        recent_repos = .{};
        try chasen.runWith(.{
            .runtime = .{
                .allocator = init.gpa,
                .io = init.io,
                .stats_fn = collectStats,
                .stats_context = &summary,
            },
            .terminal = .{
                .env_map = init.environ_map,
                .mouse = true,
                // GitFrame has text-heavy prompts; keep IME/language toggles
                // in the terminal/input-method layer.
                .keyboard_protocol = .legacy,
            },
        }, gitframe.App{
            .config = config,
            .env_map = init.environ_map,
            .user_config = user_config.*,
            .repo_session = .{
                .state_path = config_paths.state,
                .recent_repos = app_recent_repos,
            },
            .keymap = effective_keymap,
            .theme = palette,
            .executable_path = executable_path,
        });
        try printStatsSummary(init.io, summary);
        return;
    }

    const app_recent_repos = recent_repos;
    recent_repos = .{};
    try chasen.runWith(.{
        .runtime = .{
            .allocator = init.gpa,
            .io = init.io,
        },
        .terminal = .{
            .env_map = init.environ_map,
            .mouse = true,
            // GitFrame has text-heavy prompts; keep IME/language toggles
            // in the terminal/input-method layer.
            .keyboard_protocol = .legacy,
        },
    }, gitframe.App{
        .config = config,
        .env_map = init.environ_map,
        .user_config = user_config.*,
        .repo_session = .{
            .state_path = config_paths.state,
            .recent_repos = app_recent_repos,
        },
        .keymap = effective_keymap,
        .theme = palette,
        .executable_path = executable_path,
    });
}

fn startupDiagnosticWriter(file: std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Writer {
    // A positional writer does not advance a regular file's shared descriptor
    // offset. If main then returns an error, Zig's top-level error terminal can
    // overwrite the diagnostic from offset zero.
    return .initStreaming(file, io, buffer);
}

fn configForStartupFile(
    result: *const gitframe.config.LoadConfigResult,
    path: ?[]const u8,
    file: std.Io.File,
    io: std.Io,
    buffer: []u8,
) !*const gitframe.config.Config {
    var stderr = startupDiagnosticWriter(file, io, buffer);
    return configForStartup(result, path, &stderr.interface);
}

fn configForStartup(
    result: *const gitframe.config.LoadConfigResult,
    path: ?[]const u8,
    stderr: *std.Io.Writer,
) !*const gitframe.config.Config {
    return switch (result.*) {
        .success => |*owned| &owned.value,
        .failure => |failure| {
            const display_path = path orelse "<unresolved>";
            switch (failure) {
                .read_failed => try stderr.print(
                    "gitframe: cannot load config {s}: read failed\n",
                    .{display_path},
                ),
                .read_permission_denied => try stderr.print(
                    "gitframe: cannot load config {s}: permission denied\n",
                    .{display_path},
                ),
                .read_is_directory => try stderr.print(
                    "gitframe: cannot load config {s}: path is a directory\n",
                    .{display_path},
                ),
                .read_too_large => try stderr.print(
                    "gitframe: cannot load config {s}: file is too large (must be smaller than 64 KiB)\n",
                    .{display_path},
                ),
                .invalid_toml => try stderr.print(
                    "gitframe: cannot load config {s}: invalid TOML\n",
                    .{display_path},
                ),
                .unsupported_schema_version => try stderr.print(
                    "gitframe: cannot load config {s}: unsupported schema version\n",
                    .{display_path},
                ),
            }
            try stderr.flush();
            return error.InvalidConfig;
        },
    };
}

fn wantsHelp(args: []const []const u8) bool {
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

fn printHelp(io: std.Io) !void {
    var buffer: [2048]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(
        \\GitFrame
        \\
        \\Usage:
        \\  gitframe [options] [patch-file]
        \\
        \\Options:
        \\  --range <range>   Show a commit range, for example main...HEAD
        \\  --watch           Force-enable automatic reload
        \\  --no-watch        Disable automatic reload
        \\  --stats-summary   Print runtime timing summary after exit
        \\  --version         Print version and exit
        \\  -h, --help        Show this help
        \\
        \\Default:
        \\  gitframe          Show staged and unstaged changes; reload every 3 seconds
        \\
        \\Config:
        \\  [reload]
        \\  auto = true
        \\  interval_seconds = 3  # accepted range: 1..60
        \\
    );
    try stdout.flush();
}

fn printVersion(io: std.Io) !void {
    var buffer: [128]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
    try stdout.interface.print("gitframe {s}\n", .{build_options.version});
    try stdout.flush();
}

const StatsSummary = struct {
    events: u64 = 0,
    renders: u64 = 0,
    updates: u64 = 0,
    max_handle_event_ns: u64 = 0,
    max_update_ns: u64 = 0,
    max_effect_drain_ns: u64 = 0,
    max_view_ns: u64 = 0,
    max_render_ns: u64 = 0,

    fn collect(self: *StatsSummary, stats: chasen.RuntimeStats) void {
        self.events = stats.event_count;
        self.renders = if (stats.did_render) self.renders + 1 else self.renders;
        self.updates = if (stats.did_update) self.updates + 1 else self.updates;
        self.max_handle_event_ns = @max(self.max_handle_event_ns, stats.handle_event_ns);
        self.max_update_ns = @max(self.max_update_ns, stats.update_ns);
        self.max_effect_drain_ns = @max(self.max_effect_drain_ns, stats.effect_drain_ns);
        self.max_view_ns = @max(self.max_view_ns, stats.view_ns);
        self.max_render_ns = @max(self.max_render_ns, stats.render_ns);
    }
};

fn collectStats(context: ?*anyopaque, stats: chasen.RuntimeStats) void {
    const summary: *StatsSummary = @ptrCast(@alignCast(context.?));
    summary.collect(stats);
}

fn printStatsSummary(io: std.Io, summary: StatsSummary) !void {
    var buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &buffer);
    const stderr = &stderr_file_writer.interface;
    try stderr.print(
        \\GitFrame runtime stats summary
        \\  events: {d}
        \\  updates: {d}
        \\  renders: {d}
        \\  max handleEvent: {d} us
        \\  max update: {d} us
        \\  max effect drain: {d} us
        \\  max view: {d} us
        \\  max render: {d} us
        \\
    , .{
        summary.events,
        summary.updates,
        summary.renders,
        nsToUs(summary.max_handle_event_ns),
        nsToUs(summary.max_update_ns),
        nsToUs(summary.max_effect_drain_ns),
        nsToUs(summary.max_view_ns),
        nsToUs(summary.max_render_ns),
    });
    try stderr.flush();
}

fn nsToUs(ns: u64) u64 {
    return ns / std.time.ns_per_us;
}

fn printCliError(io: std.Io, err: gitframe.ParseArgsError) !void {
    var buffer: [512]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &buffer);
    const stderr = &stderr_file_writer.interface;
    try stderr.print("gitframe: {s}\nRun `gitframe --help` for usage.\n", .{@errorName(err)});
    try stderr.flush();
}

test "wantsHelp detects help flags" {
    try std.testing.expect(wantsHelp(&.{ "gitframe", "--help", "--version" }));
    try std.testing.expect(wantsHelp(&.{ "gitframe", "--cached", "--version", "-h" }));
    try std.testing.expect(!wantsHelp(&.{ "gitframe", "--version" }));
}

test "config startup borrows a successful result-owned config" {
    var result: gitframe.config.LoadConfigResult = .{ .success = .{} };
    defer result.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const config = try configForStartup(&result, null, &stderr.writer);

    try std.testing.expectEqual(gitframe.config.supported_schema_version, config.schema_version);
    try std.testing.expectEqual(@as(usize, 0), stderr.written().len);
}

test "config startup rejects every failure reason before runtime setup" {
    const Case = struct {
        failure: gitframe.config.ConfigLoadFailure,
        reason: []const u8,
    };
    const cases = [_]Case{
        .{ .failure = .read_failed, .reason = "read failed" },
        .{ .failure = .read_permission_denied, .reason = "permission denied" },
        .{ .failure = .read_is_directory, .reason = "path is a directory" },
        .{ .failure = .read_too_large, .reason = "file is too large" },
        .{ .failure = .invalid_toml, .reason = "invalid TOML" },
        .{ .failure = .unsupported_schema_version, .reason = "unsupported schema version" },
    };

    for (cases) |case| {
        var result: gitframe.config.LoadConfigResult = .{ .failure = case.failure };
        defer result.deinit();
        var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stderr.deinit();

        try std.testing.expectError(
            error.InvalidConfig,
            configForStartup(&result, "/tmp/config.toml", &stderr.writer),
        );
        try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "/tmp/config.toml") != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr.written(), case.reason) != null);
    }
}

test "config startup diagnostic survives a later error terminal in a regular file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "stderr.log", .{ .read = true });
    defer file.close(std.testing.io);

    var result: gitframe.config.LoadConfigResult = .{ .failure = .invalid_toml };
    defer result.deinit();
    var diagnostic_buffer: [512]u8 = undefined;
    try std.testing.expectError(
        error.InvalidConfig,
        configForStartupFile(
            &result,
            "/tmp/config.toml",
            file,
            std.testing.io,
            &diagnostic_buffer,
        ),
    );

    // Model the top-level error terminal writing to the same redirected stderr
    // after main returns error.InvalidConfig.
    var terminal_buffer: [128]u8 = undefined;
    var terminal_writer: std.Io.File.Writer = .initStreaming(file, std.testing.io, &terminal_buffer);
    try terminal_writer.interface.writeAll("error: InvalidConfig\n");
    try terminal_writer.flush();

    var contents: [512]u8 = undefined;
    const len = try file.readPositionalAll(std.testing.io, &contents, 0);
    try std.testing.expectEqualStrings(
        "gitframe: cannot load config /tmp/config.toml: invalid TOML\n" ++
            "error: InvalidConfig\n",
        contents[0..len],
    );
}

test "StatsSummary tracks max phase timings" {
    var summary: StatsSummary = .{};
    summary.collect(.{
        .event_kind = .key_press,
        .event_count = 1,
        .frame_count = 0,
        .did_update = true,
        .did_render = true,
        .handle_event_ns = 1_000,
        .update_ns = 2_000,
        .effect_drain_ns = 3_000,
        .view_ns = 4_000,
        .render_ns = 5_000,
    });
    summary.collect(.{
        .event_kind = .key_press,
        .event_count = 2,
        .frame_count = 0,
        .did_update = true,
        .did_render = false,
        .handle_event_ns = 10_000,
        .update_ns = 1_000,
        .effect_drain_ns = 2_000,
        .view_ns = 0,
        .render_ns = 0,
    });

    try std.testing.expectEqual(@as(u64, 2), summary.events);
    try std.testing.expectEqual(@as(u64, 2), summary.updates);
    try std.testing.expectEqual(@as(u64, 1), summary.renders);
    try std.testing.expectEqual(@as(u64, 10_000), summary.max_handle_event_ns);
    try std.testing.expectEqual(@as(u64, 2_000), summary.max_update_ns);
    try std.testing.expectEqual(@as(u64, 3_000), summary.max_effect_drain_ns);
    try std.testing.expectEqual(@as(u64, 4_000), summary.max_view_ns);
    try std.testing.expectEqual(@as(u64, 5_000), summary.max_render_ns);
}
