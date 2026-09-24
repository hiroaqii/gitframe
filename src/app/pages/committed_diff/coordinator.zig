//! Shared synchronous coordination for read-only committed-diff pages.

const std = @import("std");
const effect_origin = @import("../../effect_origin.zig");
const diff_surface = @import("../../diff_surface.zig");
const drag_auto_scroll = @import("../../drag_auto_scroll.zig");
const input = @import("input.zig");
const navigation = @import("navigation.zig");
const selection_context = @import("../../selection_context.zig");
const selection_action = @import("../../selection_action.zig");
const commit_diff = @import("../../../git/commit_diff.zig");

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
            .copy_current_line => self.copyCurrentLine(allocator),
            .copy_current_hunk => self.copyCurrentHunk(allocator),
            .branch_switch_unavailable => blk: {
                self.navigation.status.set("{s}", .{self.branch_unavailable_message});
                break :blk .{};
            },
        };
    }

    pub fn initializeAcceptedBody(
        self: Controller,
        allocator: std.mem.Allocator,
        transferred_viewport: ?diff_surface.selection_action.SelectionViewportAnchor,
    ) void {
        var adapter = self.navigation.updateAdapter();
        const cleanup = adapter.selectionMappingCleanup(allocator);
        const body = adapter.bodyController();
        if (body.controller.activeLoadedDiff()) |loaded| {
            body.controller.syncSidebarNodeToSelectedFile(loaded);
            if (transferred_viewport == null or self.navigation.diff.completed_selection == null) {
                body.initializeDiffCursorForSelectedFile();
            }
            body.clampDiffNavigation();
            if (transferred_viewport) |anchor| {
                if (self.navigation.diff.completed_selection != null) body.restoreSelectionViewportAnchor(anchor);
            }
            body.refreshSearchForSelectedFile(cleanup);
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
            .copy_diff_selection => |copy| blk: {
                if (copy.kind == .code) break :blk .{
                    .clipboard = self.ownedSelectionClipboard("diff selection", copy),
                    .auto_scroll = auto_scroll,
                    .redraw = redraw,
                };
                defer allocator.free(copy.text);
                const text = self.contextText(allocator, copy) catch |err| {
                    if (err == error.AuthorityInvalid) {
                        var cleared = try adapter.shared().apply(allocator, .{ .selection_action = .clear });
                        defer cleared.deinit(allocator);
                        adapter.applyRetentionTransition(allocator, cleared.retention_transition);
                        self.navigation.status.set("Retained selection is no longer available", .{});
                    } else self.navigation.status.set("Could not prepare selection context", .{});
                    break :blk .{ .auto_scroll = auto_scroll, .redraw = redraw };
                };
                break :blk .{
                    .clipboard = self.ownedSelectionClipboard("selection context", .{ .text = text, .generation = copy.generation }),
                    .auto_scroll = auto_scroll,
                    .redraw = redraw,
                };
            },
            .copy_hunk_diff => |text| .{
                .clipboard = self.ownedClipboard("current hunk diff", text),
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

    fn contextText(self: Controller, allocator: std.mem.Allocator, copy: diff_surface.update.SelectionCopy) selection_action.CopyError![]u8 {
        const state = self.navigation.diff;
        const accepted = state.accepted_repository_identity orelse return error.AuthorityInvalid;
        if (!accepted.matches(self.navigation.repo_epoch, self.navigation.root_identity) or
            copy.generation != state.selection_generation) return error.AuthorityInvalid;
        const root = self.navigation.repo_root orelse return error.AuthorityInvalid;
        const view = self.navigation.view();
        var resolver = view.resolver();
        const body = view.bodyView(&resolver);
        if (!body.contextCopyAvailable() or body.retainedSelectionPresentation() == null) return error.AuthorityInvalid;
        const completed = state.completed_selection orelse return error.AuthorityInvalid;
        const parsed = switch (completed.value) {
            .parsed_diff => |parsed| parsed,
            else => return error.AuthorityInvalid,
        };
        const source = switch (parsed.content) {
            .source_side => |source| source,
            .unified_diff => return error.AuthorityInvalid,
        };
        if (source.fragments.items.len == 0) return error.AuthorityInvalid;
        const pinned = state.pinned_selection_basis orelse return error.AuthorityInvalid;
        const basis: commit_diff.Basis = switch (pinned.identity) {
            .target => |target| .{ .object_format = target.object_format, .before = .{ .commit = target.diff_base_oid }, .after = target.head_oid },
            .diff_basis => |basis| basis,
        };
        var ranges: std.ArrayList(selection_context.LineRange) = .empty;
        defer ranges.deinit(allocator);
        for (source.fragments.items) |fragment| {
            if (ranges.items.len > 0) {
                const previous = &ranges.items[ranges.items.len - 1];
                if (@as(u64, previous.last) + 1 == fragment.source_start) {
                    previous.last = fragment.source_end;
                    continue;
                }
            }
            try ranges.append(allocator, .{ .first = fragment.source_start, .last = fragment.source_end });
        }
        return selection_context.format(allocator, .{
            .repository_root = root,
            .path = source.selected_path,
            .first_line = ranges.items[0].first,
            .last_line = ranges.items[0].last,
            .surface = .{ .committed = .{
                .name = switch (self.effect_origin.page_id) {
                    .compare => .compare,
                    .history => .history,
                    else => return error.AuthorityInvalid,
                },
                .basis = basis,
                .side = source.side,
                .following_ranges = ranges.items[1..],
            } },
        }, copy.text);
    }

    fn copyCurrentLine(self: Controller, allocator: std.mem.Allocator) !UpdateOutcome {
        const view = self.navigation.view();
        var resolver = view.resolver();
        var content = try view.contentView(&resolver).currentLineCopyText(allocator) orelse {
            self.navigation.status.set("no diff line selected", .{});
            return .{};
        };
        defer content.deinit(allocator);
        const label = if (view.view().effectiveDisplayMode() == .unified) "current diff line" else "current line";
        return switch (content) {
            .borrowed => |text| .{ .clipboard = self.borrowedClipboard(label, text) },
            .owned => |text| blk: {
                content = .{ .borrowed = "" };
                break :blk .{ .clipboard = self.ownedClipboard(label, text) };
            },
        };
    }

    fn copyCurrentHunk(self: Controller, allocator: std.mem.Allocator) !UpdateOutcome {
        const view = self.navigation.view();
        var resolver = view.resolver();
        var content = try view.contentView(&resolver).selectedHunkCopyText(allocator);
        defer content.deinit(allocator);
        const label = if (view.view().effectiveDisplayMode() == .unified) "current hunk diff" else "current hunk";
        switch (content) {
            .ready => |text| {
                content = .no_hunk;
                return .{ .clipboard = self.ownedClipboard(label, text) };
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
