const std = @import("std");
const gitframe = @import("gitframe");
const chasen = @import("chasen");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (wantsHelp(args)) {
        try printHelp(init.io);
        return;
    }

    var config = gitframe.parseArgs(args) catch |err| {
        try printCliError(init.io, err);
        return err;
    };
    var owns_config_source = false;
    defer if (owns_config_source) gitframe.freeSource(init.gpa, config.source);
    if (config.source == .pager) {
        config.source = gitframe.preparePagerSource(init.gpa, init.io) catch |err| {
            try printLoadError(init.io, err);
            return err;
        } orelse return;
        owns_config_source = true;
    }

    if (config.export_context) {
        exportContext(init.io, init.gpa, config) catch |err| {
            try printLoadError(init.io, err);
            return err;
        };
        return;
    }

    var review_output: gitframe.review_session.Output = .{};
    defer review_output.deinit(init.gpa);
    const review_output_ptr: ?*gitframe.review_session.Output = if (config.review_mode) &review_output else null;

    if (config.stats_summary) {
        var summary: StatsSummary = .{};
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
        }, gitframe.App{ .config = config, .env_map = init.environ_map, .review_output = review_output_ptr });
        try printStatsSummary(init.io, summary);
        try finishReviewOutputIfNeeded(init.io, config, &review_output);
        return;
    }

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
    }, gitframe.App{ .config = config, .env_map = init.environ_map, .review_output = review_output_ptr });
    try finishReviewOutputIfNeeded(init.io, config, &review_output);
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
        \\  --cached          Show staged changes
        \\  --stdin           Read unified diff from stdin
        \\  --pager           Read Git pager input from stdin and strip ANSI color
        \\  --difftool L R    Compare two paths using git diff --no-index
        \\  --range <range>   Show a commit range, for example main...HEAD
        \\  --watch           Poll and reload the active diff every 2 seconds
        \\  --stats-summary   Print runtime timing summary after exit
        \\  --export-context  Print initial selection context JSON and exit
        \\  --review          Print a review result JSON after exit
        \\  -h, --help        Show this help
        \\
        \\Default:
        \\  gitframe          Show unstaged changes in the current repository
        \\
    );
    try stdout.flush();
}

fn exportContext(io: std.Io, allocator: std.mem.Allocator, config: gitframe.CliConfig) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;
    try gitframe.exportInitialSelectionContextJson(allocator, io, config, stdout);
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

fn finishReviewOutputIfNeeded(io: std.Io, config: gitframe.CliConfig, output: *const gitframe.review_session.Output) !void {
    if (!config.review_mode) return;
    if (!output.ready) {
        try printLoadError(io, error.MissingReviewResult);
        return error.MissingReviewResult;
    }

    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(output.json.items);
    try stdout.flush();
    std.process.exit(output.exit_code);
}

fn printLoadError(io: std.Io, err: anyerror) !void {
    var buffer: [512]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &buffer);
    const stderr = &stderr_file_writer.interface;
    try stderr.print("gitframe: {s}\n", .{@errorName(err)});
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
    const args = [_][]const u8{ "gitframe", "--help" };
    try std.testing.expect(wantsHelp(args[0..]));
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
