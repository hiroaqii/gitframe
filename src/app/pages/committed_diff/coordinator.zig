//! Shared synchronous coordination for read-only committed-diff pages.

const std = @import("std");
const effect_origin = @import("../../effect_origin.zig");
const diff_surface = @import("../../diff_surface.zig");
const drag_auto_scroll = @import("../../drag_auto_scroll.zig");
const input = @import("input.zig");
const navigation = @import("navigation.zig");

pub const ClipboardEffect = struct {
    origin: effect_origin.Origin,
    label: []const u8,
    text: []const u8,
    owned_text: ?[]u8 = null,
    selection_generation: ?u64 = null,

    pub fn deinit(self: *ClipboardEffect, allocator: std.mem.Allocator) void {
        if (self.owned_text) |owned| allocator.free(owned);
        self.* = undefined;
    }
};

pub const UpdateOutcome = struct {
    clipboard: ?ClipboardEffect = null,
    auto_scroll: ?drag_auto_scroll.StepOutcome = null,
    redraw: diff_surface.update.Redraw = .default,

    pub fn deinit(self: *UpdateOutcome, allocator: std.mem.Allocator) void {
        if (self.clipboard) |*effect| effect.deinit(allocator);
        self.* = .{};
    }

    pub fn takeClipboard(self: *UpdateOutcome) ?ClipboardEffect {
        const effect = self.clipboard;
        self.clipboard = null;
        return effect;
    }
};

pub const Controller = struct {
    navigation: navigation.Controller,
    effect_origin: effect_origin.PageOrigin,
    branch_unavailable_message: []const u8,

    pub fn update(self: Controller, allocator: std.mem.Allocator, msg: input.Msg) !UpdateOutcome {
        return switch (msg) {
            .shared => |shared_msg| self.updateShared(allocator, shared_msg),
            .copy_current_line => self.copyCurrentLine(),
            .copy_current_hunk => self.copyCurrentHunk(allocator),
            .branch_switch_unavailable => blk: {
                self.navigation.status.set("{s}", .{self.branch_unavailable_message});
                break :blk .{};
            },
        };
    }

    pub fn initializeAcceptedBody(self: Controller, allocator: std.mem.Allocator) void {
        var adapter = self.navigation.updateAdapter();
        var body = adapter.bodyController();
        if (body.controller.activeLoadedDiff()) |loaded| {
            body.controller.syncSidebarNodeToSelectedFile(loaded);
            body.initializeDiffCursorForSelectedFile();
            body.clampDiffNavigation();
            body.refreshSearchForSelectedFile();
            body.controller.rebuildFileSearchProjection(allocator);
        }
    }

    fn updateShared(
        self: Controller,
        allocator: std.mem.Allocator,
        msg: diff_surface.message.Msg,
    ) !UpdateOutcome {
        var adapter = self.navigation.updateAdapter();
        var applied = try adapter.shared().apply(allocator, msg);
        defer applied.deinit(allocator);
        adapter.applyRetentionTransition(allocator, applied.retention_transition);
        const auto_scroll = applied.auto_scroll;
        const redraw = applied.redraw;
        const effect = applied.takeEffect() orelse return .{ .auto_scroll = auto_scroll, .redraw = redraw };
        return switch (effect) {
            .copy_diff_selection => |copy| .{
                .clipboard = self.ownedSelectionClipboard("diff selection", copy),
                .auto_scroll = auto_scroll,
                .redraw = redraw,
            },
            .copy_diff_header_path => |selection_value| blk: {
                const selection = selection_value;
                defer allocator.free(selection.identity.path_key);
                const view = self.navigation.view();
                var resolver = view.resolver();
                const path = view.contentView(&resolver).diffHeaderPath(selection) orelse break :blk .{};
                break :blk .{
                    .clipboard = self.borrowedClipboard("file path", path),
                    .auto_scroll = auto_scroll,
                    .redraw = redraw,
                };
            },
        };
    }

    fn copyCurrentLine(self: Controller) UpdateOutcome {
        const view = self.navigation.view();
        var resolver = view.resolver();
        const text = view.contentView(&resolver).currentLineCopyText() orelse {
            self.navigation.status.set("no diff line selected", .{});
            return .{};
        };
        return .{ .clipboard = self.borrowedClipboard("current line", text) };
    }

    fn copyCurrentHunk(self: Controller, allocator: std.mem.Allocator) !UpdateOutcome {
        const view = self.navigation.view();
        var resolver = view.resolver();
        var content = try view.contentView(&resolver).selectedHunkCopyText(allocator);
        defer content.deinit(allocator);
        switch (content) {
            .ready => |text| {
                content = .no_hunk;
                return .{ .clipboard = self.ownedClipboard("current hunk", text) };
            },
            .no_hunk => self.navigation.status.set("no hunk selected", .{}),
            .no_new_side => self.navigation.status.set("no new-side text in selected hunk", .{}),
        }
        return .{};
    }

    fn borrowedClipboard(self: Controller, label: []const u8, text: []const u8) ClipboardEffect {
        return .{ .origin = .{ .page = self.effect_origin }, .label = label, .text = text };
    }

    fn ownedClipboard(self: Controller, label: []const u8, text: []u8) ClipboardEffect {
        return .{
            .origin = .{ .page = self.effect_origin },
            .label = label,
            .text = text,
            .owned_text = text,
        };
    }

    fn ownedSelectionClipboard(
        self: Controller,
        label: []const u8,
        copy: diff_surface.update.SelectionCopy,
    ) ClipboardEffect {
        var effect = self.ownedClipboard(label, copy.text);
        effect.selection_generation = copy.generation;
        return effect;
    }
};
