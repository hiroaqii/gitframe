const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const keymap = @import("keymap");
const App = @import("../../app.zig").App;
const stash = @import("../stash.zig");
const input = @import("../input.zig");
const actions = @import("../actions.zig");
const message = @import("../message.zig");
const root_capability = @import("../../repo/root_capability.zig");
const git_status = @import("../../git/status.zig");
const branch_status = @import("../../git/branch_status.zig");
const oid = "0123456789012345678901234567890123456789";

test "stash routing respects effective binding and existing input owners" {
    const s: chasen.Key = .{ .codepoint = 's' };
    try std.testing.expect(input.keyToMsg(.{}, s).?.stash == .open);
    for ([_]input.KeyContext{
        .{ .active_page = .repository },               .{ .active_page = .history },                           .{ .active_page = .compare },          .{ .active_page = .config },
        .{ .help_mode = true },                        .{ .branch_switch_mode = true },                        .{ .remote_error_mode = true },        .{ .changes = .{ .search_mode = true } },
        .{ .changes = .{ .file_search_mode = true } }, .{ .changes = .{ .selection_owner = .keyboard_line } }, .{ .active_selection_gesture = true }, .{ .commit_panel_mode = true },
    }) |context| {
        if (input.keyToMsg(context, s)) |msg| try std.testing.expect(msg != .stash);
    }
    var config: keymap.Config = .{};
    config.set(.create_stash, .{ .plain_codepoint = ',' });
    config.set(.commit, .{ .plain_codepoint = 's' });
    try std.testing.expect(keymap.validateConfig(config));
    const effective = keymap.Effective.fromConfig(config);
    try std.testing.expect(input.keyToMsg(.{ .keymap = effective }, .{ .codepoint = ',' }).?.stash == .open);
    try std.testing.expect(input.keyToMsg(.{ .keymap = effective, .changes = .{ .keymap = effective } }, s).? != .stash);
}

test "stash message owns q s space and paste with a UTF-8 byte bound" {
    const allocator = std.testing.allocator;
    var dialog = stash.Create{
        .snapshot = try stash.Snapshot.init(allocator, "/repo", 1, .{ .device = 1, .inode = 2 }, "main", oid),
        .message = try ui.TextInput.init(allocator, .{}),
        .focus = .message,
    };
    defer dialog.deinit(allocator);
    for ("q s", 0..) |cp, index| {
        const msg = input.keyToMsg(.{ .create_stash = &dialog }, .{ .codepoint = cp, .text = "q s"[index .. index + 1] }).?;
        try dialog.edit(msg.stash.text);
    }
    try dialog.paste("\n\t\x00界");
    try std.testing.expectEqualStrings("q s  界", dialog.message.text());
    const formatted = try dialog.gitMessage(allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("GitFrame [main]: q s  界", formatted);
    try dialog.edit(.clear);
    for (0..170) |_| try dialog.edit(.{ .insert = '界' });
    try dialog.edit(.{ .insert = '界' });
    try dialog.edit(.{ .insert = 'a' });
    try dialog.edit(.{ .insert = 'b' });
    try dialog.edit(.{ .insert = 'c' });
    try std.testing.expectEqual(@as(usize, 512), dialog.message.text().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(dialog.message.text()));
    try std.testing.expect(input.keyToMsg(.{ .create_stash = &dialog }, .{ .codepoint = chasen.Key.escape }).?.stash == .cancel);
    dialog.focus = .scope;
    try std.testing.expectEqual(@as(?message.Msg, null), input.keyToMsg(.{ .create_stash = &dialog }, .{ .codepoint = 'q' }));
}

const Harness = struct {
    tmp: std.testing.TmpDir,
    app: App,

    fn init() !Harness {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(root);
        var app = App{ .allocator = allocator, .config = .{ .source = .unstaged }, .terminal_size = .{ .width = 120, .height = 32 } };
        app.repo_session.repo_state.discovery = .{ .single_repo = .{
            .label = try allocator.dupe(u8, "fixture"),
            .display_path = try allocator.dupe(u8, root),
            .canonical_root = try allocator.dupe(u8, root),
        } };
        errdefer app.repo_session.deinit(allocator);
        app.repo_session.repo_state.root = try root_capability.RootCapability.openCanonical(root);
        var status = try git_status.StatusBundle.parseOwned(allocator, "MM mixed\x00?? new\x00");
        defer status.deinit();
        try app.pages.changes.git_status.replace(root, &status);
        errdefer app.pages.changes.deinit(allocator);
        var builder = branch_status.Builder.init(allocator);
        errdefer builder.deinit();
        try builder.setBranchHead("main");
        try builder.setOid(oid);
        var branch = builder.finish();
        defer branch.deinit();
        try app.pages.changes.branch_status.replace(root, &branch);
        _ = app.pages.changes.activation.activate(app.repo_session.view().epoch(), .fresh, .fresh, .fresh);
        return .{ .tmp = tmp, .app = app };
    }

    fn deinit(self: *Harness) void {
        const allocator = std.testing.allocator;
        self.app.stash_workflow.deinit(allocator);
        self.app.remote_workflow.deinit(allocator);
        self.app.pages.changes.deinit(allocator);
        self.app.repo_session.deinit(allocator);
        self.tmp.cleanup();
    }
};

fn clearTasks(ctx: *chasen.Ctx(message.Msg)) void {
    for (ctx.takePendingTasksWith()) |task| {
        var msg = task.failed(task.ctx, .runtime_abandoned, std.testing.allocator);
        msg.deinitUndelivered(std.testing.allocator);
    }
    ctx.runtimeClearPendingEffectCopies();
}

test "stash confirmation survives auto reload, revalidates targets and refreshes exact failure" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init();
    defer harness.deinit();
    const app = &harness.app;
    var ctx: chasen.Ctx(message.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    defer clearTasks(&ctx);
    try app.update(.{ .stash = .open }, &ctx);
    try std.testing.expect(app.overlay.isCreateStash());
    app.pages.changes.activation.state.active.members.status = .failed;
    try app.update(.{ .stash = .confirm }, &ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(app.stash_workflow.create != null);
    app.pages.changes.activation.state.active.members.status = .fresh;
    const original_head = app.pages.changes.branch_status.status.head;
    app.pages.changes.branch_status.status.head = .{ .branch = "other" };
    try app.update(.{ .stash = .confirm }, &ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx._pending_tasks_with_len);
    app.pages.changes.branch_status.status.head = original_head;
    app.pages.changes.branch_status.status.oid = "advanced on the same branch";
    app.pages.changes.load.state = .{ .empty = .no_changes };
    app.pages.changes.auto_reload = .{ .activation = .forced, .interval_ns = 3 * std.time.ns_per_s };
    try app.update(.{ .stash = .tab }, &ctx);
    try app.update(.{ .stash = .{ .paste = "kept through reload" } }, &ctx);
    try app.update(.auto_reload_tick, &ctx);
    try std.testing.expectEqualStrings("kept through reload", app.stash_workflow.create.?.message.text());
    try std.testing.expectEqual(.pending, app.pages.changes.activation.state.active.members.status);
    const queued_reads = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 3), queued_reads.len);
    const reads = try allocator.dupe(@TypeOf(queued_reads[0]), queued_reads);
    defer allocator.free(reads);
    try app.update(.{ .stash = .tab }, &ctx);
    try app.update(.{ .stash = .scope_next }, &ctx);
    try std.testing.expectEqual(.staged, app.stash_workflow.create.?.scope);
    try app.update(.{ .stash = .confirm }, &ctx);
    try std.testing.expect(app.action_runtime.view().hasPending());
    try std.testing.expect(!app.pages.changes.repository_read_authority.mayStartRepositoryRead());
    const tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    var finished = tasks[0].failed(tasks[0].ctx, .runtime_abandoned, allocator);
    // Reads started before the mutation must drain without changing its inputs.
    for (reads) |task| try app.update(task.failed(task.ctx, .runtime_abandoned, allocator), &ctx);
    // A late, different token must neither reopen the fence nor touch the current owner.
    try app.update(.{ .action_finished = .{ .create_stash = .{
        .pending = .{ .generation = finished.action_finished.create_stash.pending.generation + 1, .kind = .create_stash },
        .snapshot = try finished.action_finished.create_stash.snapshot.clone(allocator),
        .scope = .all,
        .result = .{ .operation = .ok },
    } } }, &ctx);
    try std.testing.expect(app.action_runtime.view().hasPending());
    finished.action_finished.create_stash.result.saved_oid = try allocator.dupe(u8, oid);
    try app.update(finished, &ctx);
    try std.testing.expect(!app.action_runtime.view().hasPending());
    try std.testing.expect(app.pages.changes.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expect(app.overlay.isRemoteError());
    try std.testing.expect(std.mem.indexOf(u8, app.remote_workflow.remote_error_message.?, oid) != null);
    try std.testing.expectEqual(@as(usize, 3), ctx._pending_tasks_with_len);
}

test "stash queued task owns its snapshot after dialog close and cleans undelivered results" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init();
    defer harness.deinit();
    var ctx: chasen.Ctx(message.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    defer clearTasks(&ctx);
    try harness.app.update(.{ .stash = .open }, &ctx);
    try harness.app.update(.{ .stash = .confirm }, &ctx);
    try std.testing.expect(harness.app.stash_workflow.create == null);
    const tasks = ctx.takePendingTasksWith();
    const task: *actions.CreateStashTask(message.Msg) = @ptrCast(@alignCast(tasks[0].ctx));
    try std.testing.expectEqualStrings("GitFrame [main]", task.message);
    try std.testing.expectEqualStrings(oid, task.snapshot.oid);
    var msg = tasks[0].failed(tasks[0].ctx, .runtime_abandoned, allocator);
    msg.deinitUndelivered(allocator);
}
