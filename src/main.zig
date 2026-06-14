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

    const config = gitframe.parseArgs(args) catch |err| {
        try printCliError(init.io, err);
        return err;
    };

    try chasen.run(init, gitframe.App{ .config = config });
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
        \\  --range <range>   Show a commit range, for example main...HEAD
        \\  --watch           Poll and reload the active diff every 2 seconds
        \\  -h, --help        Show this help
        \\
        \\Default:
        \\  gitframe          Show unstaged changes in the current repository
        \\
    );
    try stdout.flush();
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
