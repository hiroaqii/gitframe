//! Owner-local tests for editor and clipboard shell effects.

const std = @import("std");
const chasen = @import("chasen");

const app_message = @import("message.zig");
const app_state = @import("state.zig");
const effect_origin = @import("effect_origin.zig");
const page = @import("page.zig");
const compare_page = @import("pages/compare.zig");
const repository_page = @import("pages/repository.zig");
const review_content = @import("pages/review/content.zig");
const review_page = @import("pages/review.zig");
const shell_effects = @import("shell_effects.zig");
const config_mod = @import("../config.zig");

const ShellPages = struct {
    review: review_page.ReviewPageState = .{},
    repository: repository_page.RepositoryPageState = .{},
    compare: compare_page.ComparePageState = .{},
};

const RedrawPlan = struct {
    skip_requested: bool = false,
    frame_required: bool = false,

    fn resolvesToSkip(self: RedrawPlan) bool {
        return self.skip_requested and !self.frame_required;
    }
};

const ShellHarness = struct {
    pub const Msg = app_message.Msg;

    active_page: page.Id = .review,
    repo_epoch: u64 = 0,
    pages: ShellPages = .{},
    user_config: config_mod.Config = .{},
    status: app_state.StatusMessage = .{},
    overlay: app_state.OverlayState = .{},
    shell_state: shell_effects.State = .{},
    redraw_plan: RedrawPlan = .{},

    fn origins(self: *const ShellHarness) shell_effects.OriginContext {
        return .{
            .snapshot = .{
                .active_page = self.active_page,
                .repo_epoch = self.repo_epoch,
                .review_activation_id = self.pages.review.activation.next_activation_id,
                .repository_activation_id = self.pages.repository.activation_id,
                .compare_activation_id = self.pages.compare.activation.next_activation_id,
                .push_error_instance_id = if (self.overlay.isPushError()) self.overlay.push_error_instance_id else null,
                .commit_panel_instance_id = null,
            },
            .review_repo_epoch = self.repo_epoch,
            .repository_repo_epoch = self.pages.repository.repo_epoch,
            .compare_repo_epoch = self.repo_epoch,
        };
    }

    fn shellEffects(self: *ShellHarness) shell_effects.Controller {
        return .{
            .state = &self.shell_state,
            .user_config = &self.user_config,
            .env_map = null,
            .origins = self.origins(),
            .diagnostics = .{
                .shell = &self.status,
                .review = &self.pages.review.status,
                .repository = &self.pages.repository.status,
                .compare = &self.pages.compare.status,
            },
            .redraw = .{ .skip_requested = &self.redraw_plan.skip_requested },
        };
    }

    fn copySourceSelection(
        self: *ShellHarness,
        ctx: *chasen.Ctx(Msg),
        text: []const u8,
    ) void {
        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .page = self.shellEffects().repositoryOrigin() },
            .label = "source selection",
            .text = text,
        });
    }
};
test "clipboard copy result status uses best-effort wording" {
    var app: ShellHarness = .{};
    defer app.shell_state.clipboard_copies.deinit(std.testing.allocator);
    const origin: effect_origin.Origin = .{ .page = app.shellEffects().reviewOrigin() };

    try app.shell_state.clipboard_copies.put(std.testing.allocator, 1, .{ .origin = origin, .label = "current line" });
    app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 1 }, .outcome = .sent });
    try std.testing.expectEqualStrings("clipboard copy sent: current line", app.pages.review.status.text());

    try app.shell_state.clipboard_copies.put(std.testing.allocator, 2, .{ .origin = origin, .label = "current hunk" });
    app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 2 }, .outcome = .unsupported_runtime });
    try std.testing.expectEqualStrings("clipboard copy unavailable: current hunk", app.pages.review.status.text());

    try app.shell_state.clipboard_copies.put(std.testing.allocator, 3, .{ .origin = origin, .label = "current line" });
    app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 3 }, .outcome = .{ .write_failed = "BrokenPipe" } });
    try std.testing.expectEqualStrings("clipboard copy failed: current line: BrokenPipe", app.pages.review.status.text());
    try std.testing.expectEqual(@as(usize, 0), app.shell_state.clipboard_copies.count());
}

test "inactive Review clipboard completion retains diagnostic without redraw" {
    var app: ShellHarness = .{ .active_page = .repository };
    defer app.shell_state.clipboard_copies.deinit(std.testing.allocator);
    try app.shell_state.clipboard_copies.put(std.testing.allocator, 4, .{
        .origin = .{ .page = app.shellEffects().reviewOrigin() },
        .label = "current line",
    });

    app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 4 }, .outcome = .sent });

    try std.testing.expectEqualStrings("clipboard copy sent: current line", app.pages.review.status.text());
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "repository selection late clipboard completion cannot target a new page instance" {
    var app: ShellHarness = .{
        .active_page = .repository,
        .repo_epoch = 4,
        .pages = .{ .repository = .{
            .active = true,
            .activation_id = 5,
            .repo_epoch = 4,
        } },
    };
    defer app.shell_state.clipboard_copies.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    app.copySourceSelection(&ctx, "selected source");
    app.copySourceSelection(&ctx, "selected source");
    const inactive_request_id = ctx._pending_clipboard_copies[0].request_id;
    const stale_request_id = ctx._pending_clipboard_copies[1].request_id;
    app.pages.repository.deactivate();
    app.active_page = .review;

    app.shellEffects().finishClipboard(.{ .request_id = inactive_request_id, .outcome = .sent });

    try std.testing.expectEqualStrings("clipboard copy sent: source selection", app.pages.repository.status.text());
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.pages.repository.status.clear();
    app.redraw_plan = .{};
    app.pages.repository.activation_id = 6;

    app.shellEffects().finishClipboard(.{ .request_id = stale_request_id, .outcome = .sent });

    try std.testing.expectEqual(@as(usize, 0), app.shell_state.clipboard_copies.count());
    try std.testing.expectEqualStrings("", app.pages.repository.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "closed shell surface discards clipboard completion presentation" {
    var app: ShellHarness = .{};
    defer app.shell_state.clipboard_copies.deinit(std.testing.allocator);
    app.overlay.openPushError();
    const instance_id = app.overlay.push_error_instance_id;
    app.overlay.close();
    try app.shell_state.clipboard_copies.put(std.testing.allocator, 5, .{
        .origin = .{ .shell_surface = .{ .surface = .push_error, .instance_id = instance_id } },
        .label = "push error",
    });
    try app.shell_state.clipboard_copies.put(std.testing.allocator, 7, .{
        .origin = .{ .shell_surface = .{ .surface = .push_error, .instance_id = instance_id } },
        .label = "old push error",
    });

    app.shellEffects().finishClipboard(.{
        .request_id = .{ .id = 5 },
        .outcome = .sent,
    });

    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.redraw_plan = .{};
    app.overlay.openPushError();
    try std.testing.expect(app.overlay.push_error_instance_id != instance_id);
    app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 7 }, .outcome = .sent });
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
    try std.testing.expectEqual(@as(usize, 0), app.shell_state.clipboard_copies.count());
}

test "live shell surface owns clipboard completion presentation" {
    var app: ShellHarness = .{};
    defer app.shell_state.clipboard_copies.deinit(std.testing.allocator);
    app.overlay.openPushError();
    try app.shell_state.clipboard_copies.put(std.testing.allocator, 6, .{
        .origin = .{ .shell_surface = .{
            .surface = .push_error,
            .instance_id = app.overlay.push_error_instance_id,
        } },
        .label = "push error",
    });

    app.shellEffects().finishClipboard(.{
        .request_id = .{ .id = 6 },
        .outcome = .sent,
    });

    try std.testing.expectEqualStrings("clipboard copy sent: push error", app.status.text());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
}

test "clipboard completion rejects unknown id and superseded page instance" {
    var app: ShellHarness = .{};
    defer app.shell_state.clipboard_copies.deinit(std.testing.allocator);
    const old_activation = app.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    try app.shell_state.clipboard_copies.put(std.testing.allocator, 8, .{
        .origin = .{ .page = .{ .page_id = .review, .repo_epoch = 0, .activation_id = old_activation } },
        .label = "old page",
    });
    _ = app.pages.review.activation.activate(0, .fresh, .fresh, .fresh);

    app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 999 }, .outcome = .sent });
    try std.testing.expectEqual(@as(usize, 1), app.shell_state.clipboard_copies.count());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());

    app.redraw_plan = .{};
    app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 8 }, .outcome = .sent });
    try std.testing.expectEqual(@as(usize, 0), app.shell_state.clipboard_copies.count());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "openSelectedFileInEditor blocks while git action is pending" {
    const ready: review_content.EditorTargetResult = .{ .ready = .{
        .repo_root = "/repo",
        .path = "src/main.zig",
        .line = 42,
    } };

    // Action exclusivity and target diagnostics reject before allocation.
    {
        var app: ShellHarness = .{};
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator };

        try app.shellEffects().requestEditor(
            &ctx,
            .no_repo,
            true,
            app.shellEffects().reviewOrigin(),
        );

        try std.testing.expectEqualStrings("finish current git action before opening editor", app.pages.review.status.text());
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);

        try app.shellEffects().requestEditor(
            &ctx,
            .no_repo,
            false,
            app.shellEffects().reviewOrigin(),
        );
        try std.testing.expectEqualStrings("editor unavailable for this source", app.pages.review.status.text());
    }

    // Invalid and empty configured commands retain the existing diagnostics.
    {
        var app: ShellHarness = .{};
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator };
        app.user_config.editor.argv[0] = "nvim";
        app.user_config.editor.argv[1] = "{unknown}";
        app.user_config.editor.argv_len = 2;
        try app.shellEffects().requestEditor(&ctx, ready, false, app.shellEffects().reviewOrigin());
        try std.testing.expectEqualStrings("editor config invalid: UnknownPlaceholder", app.pages.review.status.text());
        try std.testing.expect(app.shell_state.editor_foreground == null);

        app.user_config.editor.argv[0] = "";
        app.user_config.editor.argv[1] = "{path}";
        app.user_config.editor.argv_len = 2;
        try app.shellEffects().requestEditor(&ctx, ready, false, app.shellEffects().reviewOrigin());
        try std.testing.expectEqualStrings("editor command is empty", app.pages.review.status.text());
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    }

    // Queue saturation is diagnosed without committing editor correlation.
    {
        var app: ShellHarness = .{};
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator };
        defer ctx.runtimeClearPendingEffectCopies();
        _ = try ctx.terminal().runForegroundCommand(.{
            .argv = &.{"true"},
            .cwd = .inherit,
            .environment = .inherit,
            .finished = app_message.Msg.editorFinished,
        });

        try app.shellEffects().requestEditor(&ctx, ready, false, app.shellEffects().reviewOrigin());

        try std.testing.expectEqualStrings("editor command already queued", app.pages.review.status.text());
        try std.testing.expect(app.shell_state.editor_foreground == null);
        try std.testing.expectEqual(@as(u8, 1), ctx._pending_foreground_commands_len);
    }

    // Allocation failure leaves both runtime queue and owner correlation empty.
    {
        var app: ShellHarness = .{};
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = failing.allocator() };

        try std.testing.expectError(
            error.OutOfMemory,
            app.shellEffects().requestEditor(&ctx, ready, false, app.shellEffects().reviewOrigin()),
        );
        try std.testing.expect(app.shell_state.editor_foreground == null);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    }
    {
        var app: ShellHarness = .{};
        // The two editor.build allocations succeed; the runtime queue's first
        // argv-copy allocation fails before correlation is committed.
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = failing.allocator() };

        try std.testing.expectError(
            error.OutOfMemory,
            app.shellEffects().requestEditor(&ctx, ready, false, app.shellEffects().reviewOrigin()),
        );
        try std.testing.expect(app.shell_state.editor_foreground == null);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    }

    // Queue success commits the exact id. A mismatch is state-preserving; the
    // exact active completion clears first and requests one Review reload.
    {
        var app: ShellHarness = .{};
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator };
        defer ctx.runtimeClearPendingEffectCopies();
        const origin = app.shellEffects().reviewOrigin();
        try app.shellEffects().requestEditor(&ctx, ready, false, origin);
        const entry = ctx._pending_foreground_commands[0];
        const request_id = entry.request_id;
        switch (entry.runtimeChildCwd()) {
            .path => |path| try std.testing.expectEqualStrings("/repo", path),
            else => return error.ExpectedEditorPathCwd,
        }
        try std.testing.expect(entry.runtimeChildEnvironment() == null);

        try std.testing.expectEqualStrings("opening editor: src/main.zig", app.pages.review.status.text());
        try std.testing.expectEqual(request_id.id, app.shell_state.editor_foreground.?.request_id.id);
        try std.testing.expectEqual(
            shell_effects.EditorFinishOutcome.none,
            app.shellEffects().finishEditor(.{
                .request_id = .{ .id = request_id.id + 1 },
                .outcome = .{ .exited = 0 },
            }),
        );
        try std.testing.expect(app.shell_state.editor_foreground != null);

        try std.testing.expectEqual(
            shell_effects.EditorFinishOutcome.reload_review,
            app.shellEffects().finishEditor(.{
                .request_id = request_id,
                .outcome = .{ .exited = 0 },
            }),
        );
        try std.testing.expect(app.shell_state.editor_foreground == null);
        try std.testing.expectEqualStrings("editor closed", app.pages.review.status.text());
        try std.testing.expectEqual(
            shell_effects.EditorFinishOutcome.none,
            app.shellEffects().finishEditor(.{
                .request_id = request_id,
                .outcome = .{ .exited = 0 },
            }),
        );
    }

    // Same-instance inactive completion retains its origin diagnostic, while
    // a reopened Review instance consumes the terminal silently as stale.
    {
        var app: ShellHarness = .{ .active_page = .repository };
        app.shell_state.editor_foreground = .{
            .request_id = .{ .id = 80 },
            .origin = app.shellEffects().reviewOrigin(),
        };
        try std.testing.expectEqual(
            shell_effects.EditorFinishOutcome.none,
            app.shellEffects().finishEditor(.{
                .request_id = .{ .id = 80 },
                .outcome = .{ .exited = 7 },
            }),
        );
        try std.testing.expectEqualStrings("editor exited: 7", app.pages.review.status.text());
        try std.testing.expect(app.redraw_plan.resolvesToSkip());

        app.pages.review.status.clear();
        app.redraw_plan = .{};
        const old_activation = app.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
        app.shell_state.editor_foreground = .{
            .request_id = .{ .id = 81 },
            .origin = .{ .page_id = .review, .repo_epoch = 0, .activation_id = old_activation },
        };
        _ = app.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
        try std.testing.expectEqual(
            shell_effects.EditorFinishOutcome.none,
            app.shellEffects().finishEditor(.{
                .request_id = .{ .id = 81 },
                .outcome = .{ .exited = 0 },
            }),
        );
        try std.testing.expectEqualStrings("", app.pages.review.status.text());
        try std.testing.expect(app.redraw_plan.resolvesToSkip());
    }

    // Owner teardown releases the clipboard map and clears editor identity.
    {
        var state: shell_effects.State = .{
            .editor_foreground = .{
                .request_id = .{ .id = 90 },
                .origin = .{ .page_id = .review, .repo_epoch = 0, .activation_id = 0 },
            },
        };
        try state.clipboard_copies.put(std.testing.allocator, 91, .{
            .origin = .{ .page = .{ .page_id = .review, .repo_epoch = 0, .activation_id = 0 } },
            .label = "current line",
        });
        state.deinit(std.testing.allocator);
        try std.testing.expect(state.editor_foreground == null);
        try std.testing.expectEqual(@as(usize, 0), state.clipboard_copies.count());
    }
}
