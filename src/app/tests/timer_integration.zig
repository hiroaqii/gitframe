//! Timer consumer proof through the production Chasen worker and callbacks.
const std = @import("std");
const chasen = @import("chasen");
const App = @import("../../app.zig").App;
const lifecycle = @import("../workflow/action_lifecycle.zig");
const auto_reload = @import("../auto_reload.zig");
const git_history = @import("../../git/history.zig");
const root_capability = @import("../../repo/root_capability.zig");
const support = @import("../test_support.zig");
const diff_render = @import("../../diff/render.zig");

fn nextMessage(driver: *chasen.testing.TimerDriver(App.Msg), io: std.Io) !App.Msg {
    for (0..5000) |_| {
        if (try driver.nextMessage()) |msg| return msg;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TimerNotificationTimedOut;
}

fn initHistory(app: *App, allocator: std.mem.Allocator, root: []const u8) !void {
    app.* = .{ .allocator = allocator, .active_page = .history, .terminal_size = .{ .width = 80, .height = 24 } };
    app.repo_session.repo_state.root = try root_capability.RootCapability.openCanonical(root);
    app.pages.history.root_identity = app.repo_session.repo_state.root.?.identity;
    app.pages.history.load_state = .loaded;
    _ = app.pages.history.activation.activate(0, .unavailable, .unavailable, .unavailable);
    const newest = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const oldest = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    var catalog: git_history.Page = .{
        .snapshot = .{ .object_format = .sha1, .head = newest, .display = .detached },
        .records = try allocator.alloc(git_history.Record, 2),
    };
    for (catalog.records, 0..) |*record, index| record.* = .{
        .oid = if (index == 0) newest else oldest,
        .parent_count = if (index == 0) 1 else 0,
        .first_parent = if (index == 0) .{ .available = oldest } else .true_root,
        .author = try allocator.dupe(u8, "Timer test"),
        .decorations = try allocator.dupe(u8, ""),
        .subject = try allocator.dupe(u8, "selection"),
        .committer_unix = 0,
    };
    defer catalog.deinit(allocator);
    try app.pages.history.catalog.replace(allocator, &catalog);
}

fn deinitHistory(app: *App, allocator: std.mem.Allocator) void {
    app.pages.history.deinit(allocator);
    app.repo_session.deinit(allocator);
}

test "timer History preview elapsed coalesces selection into one reader and rejects duplicate terminal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var app: App = undefined;
    try initHistory(&app, std.testing.allocator, root);
    defer deinitHistory(&app, std.testing.allocator);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = undefined;
    tc.init(std.testing.allocator, threaded.io());
    defer tc.deinit();
    var driver: chasen.testing.TimerDriver(App.Msg) = undefined;
    try driver.init(&tc);
    defer driver.deinit();
    try app.update(.{ .history = .move_next }, &tc.ctx);
    try std.testing.expectEqual(@as(u64, 75 * std.time.ns_per_ms), tc.tickAt(0).?.after_ns);
    try std.testing.expectEqual(@as(usize, 0), tc.pendingTaskCount());
    try driver.drain();
    for (0..64) |i| try app.update(.{ .history = if (i % 2 == 0) .move_previous else .move_next }, &tc.ctx);
    const latest = app.pages.history.preview_state.latest.?.key;
    try std.testing.expectEqual(@as(usize, 1), app.pages.history.preview_state.activeCount());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingTickCount() + tc.pendingTaskCount());
    const elapsed = try nextMessage(&driver, threaded.io());
    try app.update(elapsed, &tc.ctx);
    try std.testing.expectEqual(@as(usize, 1), tc.pendingTaskCount());
    try std.testing.expect(latest.eql(app.pages.history.preview_state.active.reader));
    try std.testing.expectEqual(@as(usize, 0), app.pages.history.preview_state.latestCount());
    try app.update(elapsed, &tc.ctx);
    try std.testing.expectEqual(@as(usize, 1), tc.pendingTaskCount());
    try std.testing.expect(latest.eql(app.pages.history.preview_state.active.reader));
}

test "timer History preview tracking and concurrency failures retire matching waiting state" {
    for ([_]bool{ false, true }) |fail_tracking| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = counter.allocator();
        var app: App = undefined;
        try initHistory(&app, allocator, root);
        defer deinitHistory(&app, allocator);
        var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(if (fail_tracking) 1 else 0) });
        defer threaded.deinit();
        var tc: chasen.testing.TestCtx(App.Msg) = undefined;
        tc.init(allocator, threaded.io());
        defer tc.deinit();
        var driver: chasen.testing.TimerDriver(App.Msg) = undefined;
        try driver.init(&tc);
        defer driver.deinit();
        try app.update(.{ .history = .move_next }, &tc.ctx);
        const stamp = tc.tickAt(0).?.notice.history_preview;
        if (fail_tracking) counter.fail_index = counter.alloc_index;
        try driver.drain();
        const failed = (try driver.nextMessage()).?;
        try std.testing.expect(stamp.eql(failed.load_finished.history.preview.debounce.stamp));
        try std.testing.expect(failed.load_finished.history.preview.debounce.result == .failed);
        if (fail_tracking) try std.testing.expect(counter.has_induced_failure);
        counter.fail_index = std.math.maxInt(usize);
        try app.update(failed, &tc.ctx);
        try std.testing.expect(app.pages.history.preview_state.active == .none);
        try std.testing.expectEqual(@as(usize, 0), app.pages.history.preview_state.latestCount());
        try std.testing.expect(app.pages.history.preview_state.phase == .terminal);
        try std.testing.expectEqual(@as(usize, 0), tc.pendingTickCount() + tc.pendingTaskCount());
        try std.testing.expect((try driver.nextMessage()) == null);
    }
}

test "timer History preview obsolete page root catalog failure preserves newer latest" {
    const Change = enum { page, root, catalog, inactive };
    for (std.enums.values(Change)) |change| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        var app: App = undefined;
        try initHistory(&app, std.testing.allocator, root);
        defer deinitHistory(&app, std.testing.allocator);
        var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(0) });
        defer threaded.deinit();
        var tc: chasen.testing.TestCtx(App.Msg) = undefined;
        tc.init(std.testing.allocator, threaded.io());
        defer tc.deinit();
        var driver: chasen.testing.TimerDriver(App.Msg) = undefined;
        try driver.init(&tc);
        defer driver.deinit();
        try app.update(.{ .history = .move_next }, &tc.ctx);
        try driver.drain();
        const old_failure = (try driver.nextMessage()).?;
        const old_stamp = old_failure.load_finished.history.preview.debounce.stamp;
        switch (change) {
            .page => {
                app.pages.history.preview_state.invalidate(std.testing.allocator);
                _ = app.pages.history.activation.activate(0, .unavailable, .unavailable, .unavailable);
            },
            .root => {
                app.pages.history.preview_state.invalidate(std.testing.allocator);
                app.pages.history.root_identity.?.inode += 1;
            },
            .catalog => app.pages.history.preview_state.catalogPublished(std.testing.allocator),
            .inactive => {
                app.pages.history.preview_state.deactivate();
                app.active_page = .changes;
            },
        }
        if (change != .inactive) try app.update(.{ .history = .move_previous }, &tc.ctx);
        const latest = if (app.pages.history.preview_state.latest) |value| value.key else null;
        try app.update(old_failure, &tc.ctx);
        if (latest) |key| {
            try std.testing.expect(key.eql(app.pages.history.preview_state.latest.?.key));
            const new_stamp = app.pages.history.preview_state.active.debounce;
            try std.testing.expect(!old_stamp.eql(new_stamp));
            try std.testing.expectEqual(@as(usize, 1), tc.pendingTickCount());
            try app.update(old_failure, &tc.ctx);
            try std.testing.expect(new_stamp.eql(app.pages.history.preview_state.active.debounce));
        } else {
            try std.testing.expect(app.pages.history.preview_state.active == .none);
            try std.testing.expectEqual(@as(usize, 0), tc.pendingTickCount());
        }
    }
}

test "timer spinner failure suppresses immediate retry and permits next action" {
    var app: App = .{ .allocator = std.testing.allocator };
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(0) });
    defer threaded.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = undefined;
    tc.init(std.testing.allocator, threaded.io());
    defer tc.deinit();
    var driver: chasen.testing.TimerDriver(App.Msg) = undefined;
    try driver.init(&tc);
    defer driver.deinit();
    lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 11, .kind = .fetch });
    try app.update(.{ .git_action_spinner_tick = 0 }, &tc.ctx);
    try std.testing.expectEqual(@as(u64, 11), tc.everyAt(0).?.notice.spinner);
    try driver.drain();
    const failure = (try driver.nextMessage()).?;
    try app.update(failure, &tc.ctx);
    try std.testing.expect(!lifecycle.testing.spinnerTimerRunning(&app.action_runtime));
    try std.testing.expect(app.action_runtime.view().hasPending());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingEveryCount());
    try app.update(.{ .git_action_spinner_tick = 11 }, &tc.ctx);
    try std.testing.expectEqual(@as(u8, 0), app.action_runtime.view().spinnerTick());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingEveryCount());
    lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 12, .kind = .fetch });
    try app.update(.{ .git_action_spinner_tick = 0 }, &tc.ctx);
    try std.testing.expectEqual(@as(u64, 12), tc.everyAt(0).?.notice.spinner);
    try app.update(failure, &tc.ctx);
    try app.update(.{ .git_action_spinner_tick = 11 }, &tc.ctx);
    try std.testing.expect(lifecycle.testing.spinnerTimerRunning(&app.action_runtime));
    try std.testing.expectEqual(@as(u8, 0), app.action_runtime.view().spinnerTick());
}

test "timer spinner queued tick cannot animate a replacement action" {
    var app: App = .{ .allocator = std.testing.allocator };
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = undefined;
    tc.init(std.testing.allocator, threaded.io());
    defer tc.deinit();
    var driver: chasen.testing.TimerDriver(App.Msg) = undefined;
    try driver.init(&tc);
    defer driver.deinit();
    lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 1, .kind = .fetch });
    try app.update(.{ .git_action_spinner_tick = 0 }, &tc.ctx);
    try driver.drain();
    const old_tick = try nextMessage(&driver, threaded.io());
    try app.update(old_tick, &tc.ctx);
    try std.testing.expectEqual(@as(u8, 1), app.action_runtime.view().spinnerTick());
    lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 2, .kind = .fetch });
    try app.update(.{ .git_action_spinner_tick = 0 }, &tc.ctx);
    try driver.drain();
    try app.update(old_tick, &tc.ctx);
    try std.testing.expectEqual(@as(u8, 0), app.action_runtime.view().spinnerTick());
    // Cancel/join cannot retract extra old ticks already posted by the worker.
    for (0..5000) |_| {
        if (try driver.nextMessage()) |tick| {
            try app.update(tick, &tc.ctx);
            if (tick.git_action_spinner_tick == 2) {
                try std.testing.expectEqual(@as(u8, 1), app.action_runtime.view().spinnerTick());
                return;
            }
            try std.testing.expectEqual(@as(u64, 1), tick.git_action_spinner_tick);
            try std.testing.expectEqual(@as(u8, 0), app.action_runtime.view().spinnerTick());
        }
        try threaded.io().sleep(.fromMilliseconds(1), .awake);
    }
    return error.TimerNotificationTimedOut;
}

test "timer auto reload failure disables activation and preserves saved preference" {
    var app: App = .{ .allocator = std.testing.allocator };
    app.pages.changes.auto_reload = auto_reload.State.init(.enabled, app.user_config.reload);
    const saved = app.user_config.reload;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(0) });
    defer threaded.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = undefined;
    tc.init(std.testing.allocator, threaded.io());
    defer tc.deinit();
    var driver: chasen.testing.TimerDriver(App.Msg) = undefined;
    try driver.init(&tc);
    defer driver.deinit();
    try tc.ctx.timer().every(auto_reload.timer_id, app.pages.changes.auto_reload.interval_ns, .auto_reload, auto_reload.timerNotice);
    try driver.drain();
    try app.update((try driver.nextMessage()).?, &tc.ctx);
    try std.testing.expect(!app.pages.changes.auto_reload.enabled());
    try std.testing.expectEqual(saved, app.user_config.reload);
    try std.testing.expectEqualStrings("Automatic reload unavailable; use manual reload", app.status.text());
    try app.update(.auto_reload_tick, &tc.ctx);
    try std.testing.expectEqual(@as(usize, 0), tc.pendingEveryCount() + tc.pendingTaskCount());
}

test "timer drag failure retires matching intent and only new mouse input rearms" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 80, .height = 12 },
        .pages = .{ .changes = .{
            .load = support.loadState(support.loadedDiffOne()),
            .viewer = .{ .sidebar_hidden = true, .focus = .diff, .display_mode = .unified },
            .selection_owner = .{ .diff = .{
                .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
                .content = .unified_diff,
                .anchor = .{ .hunk_index = 0, .line_index = 0 },
                .focus = .{ .hunk_index = 0, .line_index = 0 },
                .anchor_cell = .{ .col = 12, .row = diff_render.body_start_row },
            } },
        } },
    };
    defer app.pages.changes.deinit(std.testing.allocator);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(0) });
    defer threaded.deinit();
    var tc: chasen.testing.TestCtx(App.Msg) = undefined;
    tc.init(std.testing.allocator, threaded.io());
    defer tc.deinit();
    var driver: chasen.testing.TimerDriver(App.Msg) = undefined;
    try driver.init(&tc);
    defer driver.deinit();
    const mouse: App.Msg = .{ .mouse_selection_drag = .{
        .pointer = .{ .col = 12, .row = 9 },
        .target = .{ .changes = .{ .col = 12, .row = 9 } },
    } };
    try app.update(mouse, &tc.ctx);
    const first = app.drag_auto_scroll.scheduled_generation.?;
    try driver.drain();
    const failed = (try driver.nextMessage()).?;
    try app.update(failed, &tc.ctx);
    try std.testing.expect(app.drag_auto_scroll.active == null);
    try std.testing.expect(app.drag_auto_scroll.scheduled_generation == null);
    try std.testing.expectEqual(@as(usize, 0), tc.pendingEveryCount());
    try app.update(mouse, &tc.ctx);
    const second = app.drag_auto_scroll.scheduled_generation.?;
    try std.testing.expect(second != first);
    try app.update(failed, &tc.ctx);
    try std.testing.expectEqual(second, app.drag_auto_scroll.scheduled_generation.?);
    try std.testing.expectEqual(second, app.drag_auto_scroll.active.?.generation);
    try std.testing.expectEqual(@as(usize, 1), tc.pendingEveryCount());
}
