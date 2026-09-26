//! Owner-local tests for editor and clipboard shell effects.

const std = @import("std");
const chasen = @import("chasen");

const app_message = @import("message.zig");
const app_state = @import("state.zig");
const content_fingerprint = @import("../content_fingerprint.zig");
const diff_surface = @import("diff_surface.zig");
const effect_origin = @import("effect_origin.zig");
const page = @import("page.zig");
const compare_page = @import("pages/compare.zig");
const history_page = @import("pages/history.zig");
const repository_page = @import("pages/repository.zig");
const changes_content = @import("pages/changes/content.zig");
const changes_page = @import("pages/changes.zig");
const shell_effects = @import("shell_effects.zig");
const config_mod = @import("../config.zig");

const ShellPages = struct {
    changes: changes_page.ChangesPageState = .{},
    repository: repository_page.RepositoryPageState = .{},
    history: history_page.HistoryPageState = .{},
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

    active_page: page.Id = .changes,
    repo_epoch: u64 = 0,
    pages: ShellPages = .{},
    user_config: config_mod.Config = .{},
    env_map: ?*std.process.Environ.Map = null,
    status: app_state.StatusMessage = .{},
    overlay: app_state.OverlayState = .{},
    shell_state: shell_effects.State = .{},
    redraw_plan: RedrawPlan = .{},

    fn origins(self: *const ShellHarness) shell_effects.OriginContext {
        return .{
            .snapshot = .{
                .active_page = self.active_page,
                .repo_epoch = self.repo_epoch,
                .changes_activation_id = self.pages.changes.activation.next_activation_id,
                .repository_activation_id = self.pages.repository.activation_id,
                .history_activation_id = self.pages.history.activation.next_activation_id,
                .compare_activation_id = self.pages.compare.activation.next_activation_id,
                .remote_error_instance_id = if (self.overlay.isRemoteError()) self.overlay.remote_error_instance_id else null,
                .commit_panel_instance_id = null,
            },
            .changes_repo_epoch = self.repo_epoch,
            .repository_repo_epoch = self.pages.repository.repo_epoch,
            .history_repo_epoch = self.repo_epoch,
            .compare_repo_epoch = self.repo_epoch,
        };
    }

    fn shellEffects(self: *ShellHarness) shell_effects.Controller {
        return .{
            .state = &self.shell_state,
            .user_config = &self.user_config,
            .env_map = self.env_map,
            .origins = self.origins(),
            .diagnostics = .{
                .shell = &self.status,
                .changes = &self.pages.changes.status,
                .repository = &self.pages.repository.status,
                .history = &self.pages.history.status,
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
    const origin: effect_origin.Origin = .{ .page = app.shellEffects().changesOrigin() };

    try app.shell_state.clipboard_copies.put(std.testing.allocator, 1, .{ .origin = origin, .label = "current line" });
    _ = app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 1 }, .outcome = .sent });
    try std.testing.expectEqualStrings("clipboard copy sent: current line", app.pages.changes.status.text());

    try app.shell_state.clipboard_copies.put(std.testing.allocator, 2, .{ .origin = origin, .label = "current hunk" });
    _ = app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 2 }, .outcome = .unsupported_runtime });
    try std.testing.expectEqualStrings("clipboard copy unavailable: current hunk", app.pages.changes.status.text());

    try app.shell_state.clipboard_copies.put(std.testing.allocator, 3, .{ .origin = origin, .label = "current line" });
    _ = app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 3 }, .outcome = .{ .write_failed = "BrokenPipe" } });
    try std.testing.expectEqualStrings("clipboard copy failed: current line: BrokenPipe", app.pages.changes.status.text());

    try app.shell_state.clipboard_copies.put(std.testing.allocator, 4, .{
        .origin = origin,
        .label = "diff selection",
        .selection_generation = 9,
    });
    const completion = app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 4 }, .outcome = .sent }) orelse
        return error.ExpectedSelectionCopyCompletion;
    try std.testing.expectEqual(page.Id.changes, completion.origin.page_id);
    try std.testing.expectEqual(@as(u64, 9), completion.generation);

    try app.shell_state.clipboard_copies.put(std.testing.allocator, 5, .{
        .origin = origin,
        .label = "diff selection",
        .selection_generation = 10,
    });
    try std.testing.expect(app.shellEffects().finishClipboard(.{
        .request_id = .{ .id = 5 },
        .outcome = .unsupported_runtime,
    }) == null);
    try std.testing.expectEqual(@as(usize, 0), app.shell_state.clipboard_copies.count());
}

test "Compare clipboard terminals and queue failure preserve retained selection authority" {
    const allocator = std.testing.allocator;
    var app: ShellHarness = .{ .active_page = .compare };
    defer app.pages.compare.deinit(allocator);
    defer app.shell_state.clipboard_copies.deinit(allocator);
    _ = app.pages.compare.activate(0);
    app.pages.compare.diff.completed_selection = .{
        .token = .{
            .repo_epoch = 0,
            .root_identity = null,
            .source = diff_surface.selection.SourceBasis.init(.{ .range = "compare" }),
            .source_session_revision = 1,
            .display = .{ .loaded = content_fingerprint.Fingerprint.init("diff") },
        },
        .value = .{ .generated_untracked = .{
            .path = try allocator.dupe(u8, "src/main.zig"),
            .range = .{
                .start = .{ .hunk_index = 0, .line_index = 0 },
                .end = .{ .hunk_index = 0, .line_index = 0 },
            },
            .content = .{ .source_side = .{
                .mode = .line,
                .fragment = .{
                    .source_start = 0,
                    .source_end = 1,
                    .text = try allocator.dupe(u8, "selected compare"),
                    .line_count = 1,
                },
            } },
        } },
    };
    app.pages.compare.diff.pinned_selection_basis = .{
        .identity = .{ .target = .{
            .object_format = .sha1,
            .base_oid = .{},
            .head_oid = .{},
            .diff_base_oid = .{},
        } },
    };
    const retained_token = app.pages.compare.diff.completed_selection.?.token;
    const retained_pin = app.pages.compare.diff.pinned_selection_basis.?;
    const origin: effect_origin.Origin = .{ .page = app.shellEffects().compareOrigin() };
    app.pages.compare.diff.selection_generation = 47;

    const outcomes = [_]app_message.ClipboardCopyOutcome{
        .sent,
        .unsupported_runtime,
        .{ .write_failed = "BrokenPipe" },
    };
    for (outcomes, 20..) |outcome, request_id| {
        try app.shell_state.clipboard_copies.put(allocator, request_id, .{
            .origin = origin,
            .label = "selection context",
            .selection_generation = app.pages.compare.diff.selection_generation,
        });
        const completion = app.shellEffects().finishClipboard(.{
            .request_id = .{ .id = request_id },
            .outcome = outcome,
        });
        if (outcome == .sent) {
            try std.testing.expectEqual(page.Id.compare, completion.?.origin.page_id);
            try std.testing.expectEqual(@as(u64, 47), completion.?.generation);
        } else try std.testing.expect(completion == null);
        try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(retained_token));
        try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(retained_pin));
    }

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failing_ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = failing.allocator() };
    app.shellEffects().queueClipboard(&failing_ctx, .{
        .origin = origin,
        .label = "diff selection",
        .text = "selected compare",
    });
    try std.testing.expectEqualStrings("could not prepare clipboard copy", app.pages.compare.status.text());
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(retained_pin));

    var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    for (0..4) |_| {
        _ = try ctx.terminal().copyToClipboard(.{
            .text = "occupied",
            .finished = ShellHarness.Msg.clipboardFinished,
        });
    }
    const clipboard_text = try app.pages.compare.diff.completed_selection.?.clipboardText(allocator);
    defer allocator.free(clipboard_text);
    app.shellEffects().queueClipboard(&ctx, .{
        .origin = origin,
        .label = "diff selection",
        .text = clipboard_text,
    });
    try std.testing.expectEqual(@as(usize, 0), app.shell_state.clipboard_copies.count());
    try std.testing.expectEqualStrings("clipboard copy already queued", app.pages.compare.status.text());
    try std.testing.expect(app.pages.compare.diff.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(app.pages.compare.diff.pinned_selection_basis.?.eql(retained_pin));
}

test "inactive Changes clipboard completion retains diagnostic without redraw" {
    var app: ShellHarness = .{ .active_page = .repository };
    defer app.shell_state.clipboard_copies.deinit(std.testing.allocator);
    try app.shell_state.clipboard_copies.put(std.testing.allocator, 4, .{
        .origin = .{ .page = app.shellEffects().changesOrigin() },
        .label = "current line",
    });

    _ = app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 4 }, .outcome = .sent });

    try std.testing.expectEqualStrings("clipboard copy sent: current line", app.pages.changes.status.text());
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
    app.active_page = .changes;

    _ = app.shellEffects().finishClipboard(.{ .request_id = inactive_request_id, .outcome = .sent });

    try std.testing.expectEqualStrings("clipboard copy sent: source selection", app.pages.repository.status.text());
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.pages.repository.status.clear();
    app.redraw_plan = .{};
    app.pages.repository.activation_id = 6;

    _ = app.shellEffects().finishClipboard(.{ .request_id = stale_request_id, .outcome = .sent });

    try std.testing.expectEqual(@as(usize, 0), app.shell_state.clipboard_copies.count());
    try std.testing.expectEqualStrings("", app.pages.repository.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.active_page = .repository;
    app.pages.repository.active = true;
    for ([_]app_message.ClipboardCopyOutcome{ .sent, .unsupported_runtime, .{ .write_failed = "BrokenPipe" } }) |outcome| {
        var context_ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator };
        defer context_ctx.runtimeClearPendingEffectCopies();
        app.shellEffects().queueClipboard(&context_ctx, .{
            .origin = .{ .page = app.shellEffects().repositoryOrigin() },
            .label = "selection context",
            .text = "Repository: /repo\nSurface: Repository\n",
            .selection_generation = 12,
        });
        try std.testing.expectEqual(@as(u8, 1), context_ctx._pending_clipboard_copies_len);
        const completion = app.shellEffects().finishClipboard(.{
            .request_id = context_ctx._pending_clipboard_copies[0].request_id,
            .outcome = outcome,
        });
        if (outcome == .sent) {
            try std.testing.expectEqual(page.Id.repository, completion.?.origin.page_id);
            try std.testing.expectEqual(@as(u64, 12), completion.?.generation);
        } else try std.testing.expect(completion == null);
    }
}

test "closed shell surface discards clipboard completion presentation" {
    var app: ShellHarness = .{};
    defer app.shell_state.clipboard_copies.deinit(std.testing.allocator);
    app.overlay.openRemoteError(.changes);
    const instance_id = app.overlay.remote_error_instance_id;
    app.overlay.close();
    try app.shell_state.clipboard_copies.put(std.testing.allocator, 5, .{
        .origin = .{ .shell_surface = .{ .surface = .remote_error, .instance_id = instance_id } },
        .label = "push error",
    });
    try app.shell_state.clipboard_copies.put(std.testing.allocator, 7, .{
        .origin = .{ .shell_surface = .{ .surface = .remote_error, .instance_id = instance_id } },
        .label = "old push error",
    });

    _ = app.shellEffects().finishClipboard(.{
        .request_id = .{ .id = 5 },
        .outcome = .sent,
    });

    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.redraw_plan = .{};
    app.overlay.openRemoteError(.changes);
    try std.testing.expect(app.overlay.remote_error_instance_id != instance_id);
    _ = app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 7 }, .outcome = .sent });
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
    try std.testing.expectEqual(@as(usize, 0), app.shell_state.clipboard_copies.count());
}

test "live shell surface owns clipboard completion presentation" {
    var app: ShellHarness = .{};
    defer app.shell_state.clipboard_copies.deinit(std.testing.allocator);
    app.overlay.openRemoteError(.changes);
    try app.shell_state.clipboard_copies.put(std.testing.allocator, 6, .{
        .origin = .{ .shell_surface = .{
            .surface = .remote_error,
            .instance_id = app.overlay.remote_error_instance_id,
        } },
        .label = "push error",
    });

    _ = app.shellEffects().finishClipboard(.{
        .request_id = .{ .id = 6 },
        .outcome = .sent,
    });

    try std.testing.expectEqualStrings("clipboard copy sent: push error", app.status.text());
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());
}

test "clipboard completion rejects unknown id and superseded page instance" {
    var app: ShellHarness = .{};
    defer app.shell_state.clipboard_copies.deinit(std.testing.allocator);
    const old_activation = app.pages.changes.activation.activate(0, .fresh, .fresh, .fresh);
    try app.shell_state.clipboard_copies.put(std.testing.allocator, 8, .{
        .origin = .{ .page = .{ .page_id = .changes, .repo_epoch = 0, .activation_id = old_activation } },
        .label = "old page",
    });
    _ = app.pages.changes.activation.activate(0, .fresh, .fresh, .fresh);

    _ = app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 999 }, .outcome = .sent });
    try std.testing.expectEqual(@as(usize, 1), app.shell_state.clipboard_copies.count());
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());

    app.redraw_plan = .{};
    _ = app.shellEffects().finishClipboard(.{ .request_id = .{ .id = 8 }, .outcome = .sent });
    try std.testing.expectEqual(@as(usize, 0), app.shell_state.clipboard_copies.count());
    try std.testing.expectEqualStrings("", app.pages.changes.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "openSelectedFileInEditor blocks while git action is pending" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("VISUAL", "test-editor");
    const ready: changes_content.EditorTargetResult = .{ .ready = .{
        .repo_root = "/repo",
        .path = "src/main.zig",
        .line = 42,
    } };

    // Action exclusivity and target diagnostics reject before allocation.
    {
        var app: ShellHarness = .{ .env_map = &env };
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator };

        try app.shellEffects().requestEditor(
            &ctx,
            .no_repo,
            true,
            app.shellEffects().changesOrigin(),
        );

        try std.testing.expectEqualStrings("finish current git action before opening editor", app.pages.changes.status.text());
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);

        try app.shellEffects().requestEditor(
            &ctx,
            .no_repo,
            false,
            app.shellEffects().changesOrigin(),
        );
        try std.testing.expectEqualStrings("editor unavailable for this source", app.pages.changes.status.text());
    }

    // Invalid and empty configured commands retain the existing diagnostics.
    {
        var app: ShellHarness = .{ .env_map = &env };
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator };
        app.user_config.editor.argv[0] = "nvim";
        app.user_config.editor.argv[1] = "{unknown}";
        app.user_config.editor.argv_len = 2;
        try app.shellEffects().requestEditor(&ctx, ready, false, app.shellEffects().changesOrigin());
        try std.testing.expectEqualStrings("editor config invalid: UnknownPlaceholder", app.pages.changes.status.text());
        try std.testing.expect(app.shell_state.editor_foreground == null);

        app.user_config.editor.argv[0] = "";
        app.user_config.editor.argv[1] = "{path}";
        app.user_config.editor.argv_len = 2;
        try app.shellEffects().requestEditor(&ctx, ready, false, app.shellEffects().changesOrigin());
        try std.testing.expectEqualStrings("editor command is empty", app.pages.changes.status.text());
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    }

    // Missing automatic candidates leave the TUI active with no queued command.
    {
        var app: ShellHarness = .{ .active_page = .repository };
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator, ._io = std.testing.io };
        try app.shellEffects().requestEditor(&ctx, ready, false, app.shellEffects().repositoryOrigin());
        try std.testing.expectEqualStrings(
            "no editor found in PATH (nvim, vim, vi); set VISUAL or EDITOR",
            app.pages.repository.status.text(),
        );
        try std.testing.expectEqualStrings("", app.pages.changes.status.text());
        try std.testing.expect(app.shell_state.editor_foreground == null);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    }

    // Repository uses the same queue but owns diagnostics and completion reloads.
    {
        var app: ShellHarness = .{ .active_page = .repository, .env_map = &env };
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator };
        defer ctx.runtimeClearPendingEffectCopies();
        const origin = app.shellEffects().repositoryOrigin();
        try app.shellEffects().requestEditor(&ctx, .directory_unsupported, false, origin);
        try std.testing.expectEqualStrings("directories cannot be opened in editor", app.pages.repository.status.text());
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
        try app.shellEffects().requestEditor(&ctx, ready, true, origin);
        try std.testing.expectEqualStrings("finish current git action before opening editor", app.pages.repository.status.text());
        app.user_config.editor.argv[0] = "nvim";
        app.user_config.editor.argv[1] = "+{line}";
        app.user_config.editor.argv[2] = "{path}";
        app.user_config.editor.argv_len = 3;
        try app.shellEffects().requestEditor(&ctx, ready, false, origin);
        const entry = ctx._pending_foreground_commands[0];
        try std.testing.expectEqualStrings("+42", entry.argv[1]);
        try std.testing.expectEqualStrings("src/main.zig", entry.argv[2]);
        try std.testing.expectEqualStrings("opening editor: src/main.zig", app.pages.repository.status.text());
        try std.testing.expectEqual(shell_effects.EditorFinishOutcome.reload_repository, app.shellEffects().finishEditor(.{
            .request_id = entry.request_id,
            .outcome = .{ .failed = .{ .stage = .spawn, .error_name = "FileNotFound" } },
        }));
        try std.testing.expectEqualStrings("editor spawn failed: FileNotFound", app.pages.repository.status.text());
        try std.testing.expect(app.shell_state.editor_foreground == null);
        try std.testing.expectEqualStrings("", app.pages.changes.status.text());
    }

    // Queue saturation is diagnosed without committing editor correlation.
    {
        var app: ShellHarness = .{ .env_map = &env };
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator };
        defer ctx.runtimeClearPendingEffectCopies();
        _ = try ctx.terminal().runForegroundCommand(.{
            .argv = &.{"true"},
            .cwd = .inherit,
            .environment = .inherit,
            .finished = app_message.Msg.editorFinished,
        });

        try app.shellEffects().requestEditor(&ctx, ready, false, app.shellEffects().changesOrigin());

        try std.testing.expectEqualStrings("editor command already queued", app.pages.changes.status.text());
        try std.testing.expect(app.shell_state.editor_foreground == null);
        try std.testing.expectEqual(@as(u8, 1), ctx._pending_foreground_commands_len);
    }

    // Allocation failure leaves both runtime queue and owner correlation empty.
    {
        var app: ShellHarness = .{ .env_map = &env };
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = failing.allocator() };

        try std.testing.expectError(
            error.OutOfMemory,
            app.shellEffects().requestEditor(&ctx, ready, false, app.shellEffects().changesOrigin()),
        );
        try std.testing.expect(app.shell_state.editor_foreground == null);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    }
    {
        var app: ShellHarness = .{ .env_map = &env };
        // The two editor.build allocations succeed; the runtime queue's first
        // argv-copy allocation fails before correlation is committed.
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = failing.allocator() };

        try std.testing.expectError(
            error.OutOfMemory,
            app.shellEffects().requestEditor(&ctx, ready, false, app.shellEffects().changesOrigin()),
        );
        try std.testing.expect(app.shell_state.editor_foreground == null);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    }

    // Queue success commits the exact id. A mismatch is state-preserving; the
    // exact active completion clears first and requests one Changes reload.
    {
        var app: ShellHarness = .{ .env_map = &env };
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator };
        defer ctx.runtimeClearPendingEffectCopies();
        const origin = app.shellEffects().changesOrigin();
        try app.shellEffects().requestEditor(&ctx, ready, false, origin);
        const entry = ctx._pending_foreground_commands[0];
        const request_id = entry.request_id;
        switch (entry.runtimeChildCwd()) {
            .path => |path| try std.testing.expectEqualStrings("/repo", path),
            else => return error.ExpectedEditorPathCwd,
        }
        try std.testing.expect(entry.runtimeChildEnvironment() == null);

        try std.testing.expectEqualStrings("opening editor: src/main.zig", app.pages.changes.status.text());
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
            shell_effects.EditorFinishOutcome.reload_changes,
            app.shellEffects().finishEditor(.{
                .request_id = request_id,
                .outcome = .{ .exited = 0 },
            }),
        );
        try std.testing.expect(app.shell_state.editor_foreground == null);
        try std.testing.expectEqualStrings("editor closed", app.pages.changes.status.text());
        try std.testing.expectEqual(
            shell_effects.EditorFinishOutcome.none,
            app.shellEffects().finishEditor(.{
                .request_id = request_id,
                .outcome = .{ .exited = 0 },
            }),
        );
    }

    // Same-instance inactive completion retains its origin diagnostic, while
    // a reopened Changes instance consumes the terminal silently as stale.
    {
        var app: ShellHarness = .{ .active_page = .repository, .env_map = &env };
        app.shell_state.editor_foreground = .{
            .request_id = .{ .id = 80 },
            .origin = app.shellEffects().changesOrigin(),
        };
        try std.testing.expectEqual(
            shell_effects.EditorFinishOutcome.none,
            app.shellEffects().finishEditor(.{
                .request_id = .{ .id = 80 },
                .outcome = .{ .exited = 7 },
            }),
        );
        try std.testing.expectEqualStrings("editor exited: 7", app.pages.changes.status.text());
        try std.testing.expect(app.redraw_plan.resolvesToSkip());

        app.pages.changes.status.clear();
        app.redraw_plan = .{};
        const old_activation = app.pages.changes.activation.activate(0, .fresh, .fresh, .fresh);
        app.shell_state.editor_foreground = .{
            .request_id = .{ .id = 81 },
            .origin = .{ .page_id = .changes, .repo_epoch = 0, .activation_id = old_activation },
        };
        _ = app.pages.changes.activation.activate(0, .fresh, .fresh, .fresh);
        try std.testing.expectEqual(
            shell_effects.EditorFinishOutcome.none,
            app.shellEffects().finishEditor(.{
                .request_id = .{ .id = 81 },
                .outcome = .{ .exited = 0 },
            }),
        );
        try std.testing.expectEqualStrings("", app.pages.changes.status.text());
        try std.testing.expect(app.redraw_plan.resolvesToSkip());
    }

    // New terminals retain origin routing and consume correlation exactly once.
    for ([_]struct {
        outcome: chasen.ForegroundCommandOutcome,
        expected: []const u8,
    }{
        .{ .outcome = .{ .stopped = 20 }, .expected = "editor stopped and terminated: 20" },
        .{ .outcome = .{ .failed = .{ .stage = .handoff, .error_name = "NotForeground" } }, .expected = "editor handoff failed: NotForeground" },
        .{ .outcome = .runtime_abandoned, .expected = "unchanged" },
    }) |case| {
        var app: ShellHarness = .{ .active_page = .repository, .env_map = &env };
        app.pages.repository.status.set("unchanged", .{});
        app.shell_state.editor_foreground = .{
            .request_id = .{ .id = 89 },
            .origin = app.shellEffects().repositoryOrigin(),
        };
        const result: chasen.ForegroundCommandResult = .{
            .request_id = .{ .id = 89 },
            .outcome = case.outcome,
        };
        try std.testing.expectEqual(
            if (case.outcome == .runtime_abandoned) shell_effects.EditorFinishOutcome.none else .reload_repository,
            app.shellEffects().finishEditor(result),
        );
        try std.testing.expect(app.shell_state.editor_foreground == null);
        try std.testing.expectEqualStrings(case.expected, app.pages.repository.status.text());
        try std.testing.expectEqualStrings("", app.pages.changes.status.text());
        try std.testing.expectEqual(shell_effects.EditorFinishOutcome.none, app.shellEffects().finishEditor(result));
    }
    {
        var app: ShellHarness = .{ .env_map = &env };
        var ctx: chasen.Ctx(ShellHarness.Msg) = .{ ._allocator = std.testing.allocator };
        ctx.quit();
        app.pages.changes.status.set("closing", .{});
        try app.shellEffects().requestEditor(&ctx, ready, false, app.shellEffects().changesOrigin());
        try std.testing.expectEqualStrings("closing", app.pages.changes.status.text());
        try std.testing.expect(app.shell_state.editor_foreground == null);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    }

    // Owner teardown releases the clipboard map and clears editor identity.
    {
        var state: shell_effects.State = .{
            .editor_foreground = .{
                .request_id = .{ .id = 90 },
                .origin = .{ .page_id = .changes, .repo_epoch = 0, .activation_id = 0 },
            },
        };
        try state.clipboard_copies.put(std.testing.allocator, 91, .{
            .origin = .{ .page = .{ .page_id = .changes, .repo_epoch = 0, .activation_id = 0 } },
            .label = "current line",
        });
        state.deinit(std.testing.allocator);
        try std.testing.expect(state.editor_foreground == null);
        try std.testing.expectEqual(@as(usize, 0), state.clipboard_copies.count());
    }
}
