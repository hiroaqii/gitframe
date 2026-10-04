const std = @import("std");
const chasen = @import("chasen");
const App = @import("../../app.zig").App;
const transition = @import("../screen_transition.zig");
const page = @import("../page.zig");
const support = @import("../test_support.zig");

test "screen transition consumes accepted failed and replaced publication once" {
    var state: transition.State = .idle;
    const identity = page.RequestIdentity.history(4, 1);
    state.arm(identity);
    try std.testing.expect(!state.publish(identity, .none));
    try std.testing.expect(state.publish(identity, .accepted));
    for (1..84) |_| try std.testing.expect(state.step());
    try std.testing.expect(state == .idle);
    try std.testing.expect(!state.publish(identity, .accepted));
    state.arm(identity);
    try std.testing.expect(!state.publish(identity, .failed));
    try std.testing.expect(!state.publish(identity, .accepted));
    state.arm(identity);
    try std.testing.expect(!state.publish(page.RequestIdentity.history(4, 2), .accepted));
    try std.testing.expect(state == .idle);
}

test "screen transition starts only after an accepted Changes source publication" {
    var app: App = .{ .allocator = std.testing.allocator, .config = .{ .source = .{ .patch_file = "fixture.patch" } } };
    defer app.pages.changes.deinit(std.testing.allocator);
    var tc: chasen.testing.TestCtx(App.Msg) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();
    defer tc.resetTransient();
    const activation = app.pages.changes.activation.activate(0, .pending, .unavailable, .unavailable);
    const generation = app.pages.changes.load.beginDiffLoad();
    app.pages.changes.pending_reload = .{ .generation = generation, .kind = .initial };
    app.pages.changes.load.state = .loading;
    app.screen_transition.arm(page.RequestIdentity.changes(0, activation));
    // tmux may produce an unmapped F3 event during terminal setup. Only an
    // already visible animation should intercept such otherwise ignored input.
    try std.testing.expect(app.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.f3 } }) == null);
    // The runtime's first resize must not suppress the startup effect.
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 24 } }, &tc.ctx);
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 24 } }, &tc.ctx);
    try app.update(.{ .load_finished = .{ .changes = .{ .source = .{
        .identity = page.RequestIdentity.changes(99, activation),
        .generation = generation - 1,
        .result = .empty,
    } } } }, &tc.ctx);
    try std.testing.expect(app.screen_transition == .waiting);
    tc.resetTransient();
    try app.update(.{ .load_finished = .{ .changes = .{ .source = .{
        .identity = page.RequestIdentity.changes(0, activation),
        .generation = generation,
        .result = .empty,
    } } } }, &tc.ctx);
    try std.testing.expect(app.screen_transition == .running);
    try std.testing.expect(tc.frameRequested());
    try std.testing.expect(!tc.redrawSuppressed());
    for (1..84) |_| {
        tc.resetTransient();
        try app.update(.transition_frame, &tc.ctx);
        try std.testing.expect(!tc.redrawSuppressed());
    }
    try std.testing.expect(app.screen_transition == .idle);
    try std.testing.expect(!tc.frameRequested());
    tc.resetTransient();
    try app.update(.transition_frame, &tc.ctx);
    try std.testing.expect(tc.redrawSuppressed());
}

test "screen transition key and mouse cancel while preserving the original action" {
    var app: App = .{ .terminal_size = .{ .width = 80, .height = 24 } };
    var tc: chasen.testing.TestCtx(App.Msg) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();
    defer tc.resetTransient();
    app.screen_transition = .{ .running = 12 };
    const key = app.handleEvent(.{ .key_press = .{ .codepoint = '?' } }).?;
    try app.update(key, &tc.ctx);
    try std.testing.expect(app.screen_transition == .idle);
    try std.testing.expect(app.overlay.isHelp());
    try std.testing.expect(!tc.redrawSuppressed());
    app.overlay.close();
    tc.resetTransient();
    app.screen_transition = .{ .running = 12 };
    const target = page.tab(.repository);
    const mouse = app.handleEvent(support.mouseEvent(target.col + 1, 1, .left)).?;
    try app.update(mouse, &tc.ctx);
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.screen_transition == .idle);
    try std.testing.expect(!tc.frameRequested());
}

test "screen transition unmapped input resize and focus loss cancel cleanly" {
    const events = [_]chasen.Event{
        .{ .key_press = .{ .codepoint = 0 } },
        support.mouseEvent(0, 0, .left),
        .{ .paste = "ignored" },
        support.mouseEvent(0, 0, .wheel_up),
        .focus_out,
        .{ .winsize = .{ .cols = 100, .rows = 30, .x_pixel = 0, .y_pixel = 0 } },
    };
    for (events) |event| {
        var app: App = .{ .terminal_size = .{ .width = 80, .height = 24 } };
        var tc: chasen.testing.TestCtx(App.Msg) = undefined;
        tc.init(std.testing.allocator, std.testing.io);
        defer tc.deinit();
        defer tc.resetTransient();
        app.screen_transition = .{ .running = 20 };
        try app.update(app.handleEvent(event).?, &tc.ctx);
        try std.testing.expect(app.screen_transition == .idle);
        try std.testing.expect(!tc.redrawSuppressed());
    }
}

test "screen transition redraw requirement wins over background skip" {
    var app: App = .{ .screen_transition = .{ .running = 3 } };
    var tc: chasen.testing.TestCtx(App.Msg) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();
    defer tc.resetTransient();
    try app.update(.{ .git_action_spinner_tick = 0 }, &tc.ctx);
    try std.testing.expect(app.screen_transition == .running);
    try std.testing.expect(!tc.redrawSuppressed());
}

test "screen transition rendering masks glyphs and styled blanks then restores exact cells" {
    var surface: chasen.testing.TestSurface = undefined;
    try surface.init(20, 4);
    defer surface.deinit();
    const style: chasen.TextStyle = .{ .bold = true, .bg = .{ .rgb = .{ 0x17, 0x33, 0x21 } } };
    _ = surface.surface.borrowTextAt(0, 3, "日本語 text", style);
    surface.surface.writeCell(12, 3, .{ .char = .{ .grapheme = "語", .width = 0 }, .style = style });
    surface.surface.writeCell(15, 3, .{ .style = style });
    var original: [20]chasen.Cell = undefined;
    for (&original, 0..) |*cell, col| cell.* = surface.surface.readCell(@intCast(col), 3).?;
    transition.apply(&surface.surface, 1);
    for ([_]u16{ 0, 1, 2, 3, 4, 5, 12, 13, 15 }) |col| {
        try std.testing.expectEqualStrings(" ", surface.cellText(col, 3));
        try std.testing.expect(surface.surface.readCell(col, 3).?.style.bg.eql(.default));
    }
    // Each view paints the destination afresh; cancellation and the last frame
    // therefore recover both glyphs and style without storing a snapshot.
    for (original, 0..) |cell, col| surface.surface.writeCell(@intCast(col), 3, cell);
    transition.apply(&surface.surface, 84);
    for (original, 0..) |cell, col| {
        const restored = surface.surface.readCell(@intCast(col), 3).?;
        try std.testing.expectEqualStrings(cell.char.grapheme, restored.char.grapheme);
        try std.testing.expectEqualDeep(cell.style, restored.style);
        try std.testing.expectEqual(cell.char.width, restored.char.width);
    }
    transition.apply(&surface.surface, 30);
    for (0..20) |col| {
        const cell = surface.surface.readCell(@intCast(col), 3).?;
        if (!cell.isBlank() and !std.mem.eql(u8, cell.char.grapheme, "語") and
            !std.mem.eql(u8, cell.char.grapheme, "日") and !std.mem.eql(u8, cell.char.grapheme, "本"))
            try std.testing.expectEqual(@as(u16, 1), cell.char.width);
    }
    try std.testing.expect(surface.surface.readCell(19, 3).?.isBlank());
}

test "screen transition release and movement keep the effect and disabled ignores frames" {
    var app: App = .{ .terminal_size = .{ .width = 80, .height = 24 }, .screen_transition = .{ .running = 12 } };
    var tc: chasen.testing.TestCtx(App.Msg) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();
    defer tc.resetTransient();
    for ([_]chasen.Event{
        support.mouseEventTyped(0, 0, .left, .release),
        support.mouseEventTyped(0, 0, .left, .motion),
    }) |event| {
        if (app.handleEvent(event)) |msg| try app.update(msg, &tc.ctx);
        try std.testing.expect(app.screen_transition == .running);
    }
    app.config.transitions = false;
    app.screen_transition = .idle;
    try std.testing.expect(app.handleEvent(.{ .frame = .{ .now_ns = 1, .delta_ns = 1, .index = 0 } }) == null);
    try app.update(.{ .git_action_spinner_tick = 0 }, &tc.ctx);
    try std.testing.expect(!tc.frameRequested());
}
