//! Shell-owned editor and clipboard effect lifecycles.
//!
//! Page owners resolve borrowed content synchronously. This controller queues
//! the physical terminal effect, records only immutable correlation metadata,
//! and admits exactly one matching completion against the captured semantic
//! origin. It never starts Review reads directly; typed outcomes return that
//! composition work to the root shell.

const std = @import("std");
const chasen = @import("chasen");

const app_message = @import("message.zig");
const app_state = @import("state.zig");
const effect_origin = @import("effect_origin.zig");
const review_content = @import("pages/review/content.zig");
const config_mod = @import("../config.zig");
const editor = @import("../editor.zig");

pub const EditorForegroundState = struct {
    request_id: chasen.ForegroundCommandRequestId,
    origin: effect_origin.PageOrigin,
};

pub const ClipboardCopyState = struct {
    origin: effect_origin.Origin,
    /// Caller-provided static label; only literal labels are retained after
    /// synchronous queueing. Clipboard text itself is copied by the runtime.
    label: []const u8,
};

pub const State = struct {
    editor_foreground: ?EditorForegroundState = null,
    clipboard_copies: std.AutoHashMapUnmanaged(u64, ClipboardCopyState) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.editor_foreground = null;
        self.clipboard_copies.deinit(allocator);
        self.* = .{};
    }

    pub fn view(self: *const State) View {
        return .{ .state = self };
    }
};

pub const View = struct {
    state: *const State,

    pub fn hasEditorForeground(self: View) bool {
        return self.state.editor_foreground != null;
    }

    pub fn pendingClipboardCount(self: View) usize {
        return self.state.clipboard_copies.count();
    }
};

pub const OriginContext = struct {
    snapshot: effect_origin.Snapshot,
    review_repo_epoch: u64,
    repository_repo_epoch: u64,
    compare_repo_epoch: u64,

    pub fn review(self: OriginContext) effect_origin.PageOrigin {
        return .{
            .page_id = .review,
            .repo_epoch = self.review_repo_epoch,
            .activation_id = self.snapshot.review_activation_id,
        };
    }

    pub fn repository(self: OriginContext) effect_origin.PageOrigin {
        return .{
            .page_id = .repository,
            .repo_epoch = self.repository_repo_epoch,
            .activation_id = self.snapshot.repository_activation_id,
        };
    }

    pub fn compare(self: OriginContext) effect_origin.PageOrigin {
        return .{
            .page_id = .compare,
            .repo_epoch = self.compare_repo_epoch,
            .activation_id = self.snapshot.compare_activation_id,
        };
    }
};

pub const DiagnosticPorts = struct {
    shell: *app_state.StatusMessage,
    review: *app_state.StatusMessage,
    repository: *app_state.StatusMessage,
    compare: *app_state.StatusMessage,
};

pub const RedrawSink = struct {
    skip_requested: *bool,

    fn requestSkip(self: RedrawSink) void {
        self.skip_requested.* = true;
    }
};

pub const CopyRequest = struct {
    origin: effect_origin.Origin,
    /// Must have static lifetime because the correlation map retains it until
    /// the asynchronous completion is admitted.
    label: []const u8,
    text: []const u8,
};

pub const EditorFinishOutcome = enum {
    none,
    reload_review,
};

pub const Controller = struct {
    state: *State,
    user_config: *const config_mod.Config,
    env_map: ?*std.process.Environ.Map,
    origins: OriginContext,
    diagnostics: DiagnosticPorts,
    redraw: RedrawSink,

    pub fn view(self: Controller) View {
        return self.state.view();
    }

    pub fn reviewOrigin(self: Controller) effect_origin.PageOrigin {
        return self.origins.review();
    }

    pub fn repositoryOrigin(self: Controller) effect_origin.PageOrigin {
        return self.origins.repository();
    }

    pub fn compareOrigin(self: Controller) effect_origin.PageOrigin {
        return self.origins.compare();
    }

    pub fn requestEditor(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        target_result: review_content.EditorTargetResult,
        action_busy: bool,
        origin: effect_origin.PageOrigin,
    ) !void {
        if (action_busy) {
            self.diagnostics.review.set("finish current git action before opening editor", .{});
            return;
        }

        const target = switch (target_result) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.diagnostics.review.set("editor unavailable for this source", .{});
                return;
            },
            .no_path => {
                self.diagnostics.review.set("no file selected", .{});
                return;
            },
            .stale_source => {
                self.diagnostics.review.set("source is stale; press r to reload", .{});
                return;
            },
            .directory_unsupported => {
                self.diagnostics.review.set("directories cannot be opened in editor", .{});
                return;
            },
            .deleted_file => {
                self.diagnostics.review.set("deleted files cannot be opened", .{});
                return;
            },
        };

        var argv = editor.build(ctx.allocator(), self.user_config.editor, self.env_map, .{
            .repo_root = target.repo_root,
            .path = target.path,
            .line = target.line,
            .column = 1,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.EmptyArgv => {
                self.diagnostics.review.set("editor command is empty", .{});
                return;
            },
            error.MissingPathPlaceholder, error.UnknownPlaceholder, error.TooManyArguments => {
                self.diagnostics.review.set("editor config invalid: {s}", .{@errorName(err)});
                return;
            },
        };
        defer argv.deinit(ctx.allocator());
        if (argv.argv.len == 0) {
            self.diagnostics.review.set("editor command is empty", .{});
            return;
        }

        const request_id = ctx.terminal().runForegroundCommand(.{
            .argv = argv.argv,
            .cwd = target.repo_root,
            .finished = app_message.Msg.editorFinished,
        }) catch |err| switch (err) {
            error.ForegroundCommandLimitExceeded => {
                self.diagnostics.review.set("editor command already queued", .{});
                return;
            },
            error.ForegroundCommandEmptyArgv => {
                self.diagnostics.review.set("editor command is empty", .{});
                return;
            },
            error.OutOfMemory => return err,
        };
        self.state.editor_foreground = .{
            .request_id = request_id,
            .origin = origin,
        };
        self.diagnostics.review.set("opening editor: {s}", .{target.path});
    }

    pub fn finishEditor(
        self: Controller,
        result: chasen.ForegroundCommandResult,
    ) EditorFinishOutcome {
        const foreground = self.state.editor_foreground orelse return .none;
        if (foreground.request_id.id != result.request_id.id) return .none;
        self.state.editor_foreground = null;
        const origin: effect_origin.Origin = .{ .page = foreground.origin };
        const liveness = effect_origin.classify(origin, self.origins.snapshot);
        if (liveness == .stale) {
            self.redraw.requestSkip();
            return .none;
        }

        switch (result.outcome) {
            .exited => |code| {
                if (code == 0) {
                    self.setEffectStatus(origin, "editor closed", .{});
                } else {
                    self.setEffectStatus(origin, "editor exited: {d}", .{code});
                }
            },
            .signaled => |signal| self.setEffectStatus(origin, "editor signal: {d}", .{signal}),
            .spawn_failed => |err| self.setEffectStatus(origin, "editor spawn failed: {s}", .{err}),
            .wait_failed => |err| self.setEffectStatus(origin, "editor wait failed: {s}", .{err}),
        }

        if (liveness == .live_inactive) {
            self.redraw.requestSkip();
            return .none;
        }
        return if (foreground.origin.page_id == .review) .reload_review else .none;
    }

    pub fn queueClipboard(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        request: CopyRequest,
    ) void {
        if (request.text.len == 0) {
            self.setEffectStatus(request.origin, "nothing to copy: {s}", .{request.label});
            return;
        }
        self.state.clipboard_copies.ensureUnusedCapacity(ctx.allocator(), 1) catch {
            self.setEffectStatus(request.origin, "could not track clipboard copy", .{});
            return;
        };
        const request_id = ctx.terminal().copyToClipboard(.{
            .text = request.text,
            .finished = app_message.Msg.clipboardFinished,
        }) catch |err| switch (err) {
            error.OutOfMemory => {
                self.setEffectStatus(request.origin, "could not prepare clipboard copy", .{});
                return;
            },
            error.ClipboardCopyLimitExceeded => {
                self.setEffectStatus(request.origin, "clipboard copy already queued", .{});
                return;
            },
        };
        self.state.clipboard_copies.putAssumeCapacity(request_id.id, .{
            .origin = request.origin,
            .label = request.label,
        });
    }

    pub fn finishClipboard(
        self: Controller,
        finished: app_message.ClipboardCopyFinished,
    ) void {
        const removed = self.state.clipboard_copies.fetchRemove(finished.request_id.id) orelse {
            self.redraw.requestSkip();
            return;
        };
        const pending = removed.value;
        const liveness = effect_origin.classify(pending.origin, self.origins.snapshot);
        if (liveness == .stale) {
            self.redraw.requestSkip();
            return;
        }
        switch (finished.outcome) {
            .sent => self.setEffectStatus(pending.origin, "clipboard copy sent: {s}", .{pending.label}),
            .unsupported_runtime => self.setEffectStatus(pending.origin, "clipboard copy unavailable: {s}", .{pending.label}),
            .write_failed => |err| self.setEffectStatus(pending.origin, "clipboard copy failed: {s}: {s}", .{ pending.label, err }),
        }
        if (liveness == .live_inactive) self.redraw.requestSkip();
    }

    fn setEffectStatus(
        self: Controller,
        origin: effect_origin.Origin,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        switch (origin) {
            .page => |captured| switch (captured.page_id) {
                .review => self.diagnostics.review.set(fmt, args),
                .repository => self.diagnostics.repository.set(fmt, args),
                .compare => self.diagnostics.compare.set(fmt, args),
                .config => self.diagnostics.shell.set(fmt, args),
            },
            .shell_surface => self.diagnostics.shell.set(fmt, args),
        }
    }
};
