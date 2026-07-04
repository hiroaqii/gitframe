const std = @import("std");

const app_prompt = @import("prompt.zig");
const repo_discovery = @import("../repo/discovery.zig");
const repo_state = @import("../repo/state.zig");

pub const ItemSource = union(enum) {
    active_repo,
    workspace_repo: usize,
    pending_workspace_repo: usize,
    recent_repo: usize,
    recent_workspace: usize,
};

pub const Item = struct {
    label: []u8,
    detail: []u8,
    source: ItemSource,

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.detail);
        self.* = undefined;
    }
};

pub const ItemList = std.ArrayList(Item);

pub const EditResult = enum {
    none,
    refresh_filter,
    filter_too_long,
    path_changed,
};

pub fn refreshFilter(
    allocator: std.mem.Allocator,
    picker: *app_prompt.RepoPickerState,
    items: *ItemList,
    pending_discovery: ?repo_discovery.DiscoveryResult,
    active_discovery: ?repo_discovery.DiscoveryResult,
    recent: *const repo_state.RecentStore,
) !void {
    clearItems(items, allocator);

    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(allocator);

    if (pending_discovery) |discovery| {
        switch (discovery) {
            .workspace => |workspace| {
                for (workspace.repos, 0..) |repo, index| {
                    try appendItem(allocator, items, repo.label, repo.canonical_root, .{ .pending_workspace_repo = index });
                }
            },
            .single_repo, .none => {},
        }
    } else if (active_discovery) |discovery| {
        switch (discovery) {
            .single_repo => |entry| {
                try appendItem(allocator, items, entry.label, entry.canonical_root, .active_repo);
            },
            .workspace => |workspace| {
                for (workspace.repos, 0..) |repo, index| {
                    try appendItem(allocator, items, repo.label, repo.canonical_root, .{ .workspace_repo = index });
                }
            },
            .none => {},
        }
    }

    for (recent.entries.items, 0..) |entry, index| {
        if (alreadyHasPath(pending_discovery, active_discovery, items.items, entry.path)) continue;
        const source: ItemSource = switch (entry.kind) {
            .repo => .{ .recent_repo = index },
            .workspace => .{ .recent_workspace = index },
        };
        try appendItem(allocator, items, std.fs.path.basename(entry.path), entry.path, source);
    }

    for (items.items) |item| {
        try labels.append(allocator, item.label);
    }

    // ListFilter owns filtered indexes; labels remain borrowed from items,
    // which must outlive the filter until the picker is refreshed or closed.
    const query = if (picker.input_mode == .filter) picker.list.input.slice() else "";
    try picker.list.filter.apply(allocator, labels.items, query);
}

pub fn focusOnActive(picker: *app_prompt.RepoPickerState, items: []const Item, active_index: usize) void {
    var visible_index: usize = 0;
    while (visible_index < picker.list.filter.labels.len) : (visible_index += 1) {
        const source_index = picker.list.filter.sourceIndex(visible_index) orelse continue;
        if (source_index >= items.len) continue;
        const active = switch (items[source_index].source) {
            .active_repo => true,
            .workspace_repo => |repo_index| repo_index == active_index,
            .pending_workspace_repo, .recent_repo, .recent_workspace => false,
        };
        if (!active) continue;
        while (picker.list.filter.list.focusedIndex() < visible_index) {
            picker.list.filter.update(.move_next);
        }
        return;
    }
}

pub fn focusVisibleIndex(picker: *app_prompt.RepoPickerState, preferred_index: usize) void {
    const len = picker.list.filter.labels.len;
    picker.list.filter.list.focus.len = len;
    picker.list.filter.list.focus.index = if (len == 0) 0 else @min(preferred_index, len - 1);
}

pub fn resolveSelection(picker: *const app_prompt.RepoPickerState, items: []const Item) ?ItemSource {
    const item = selectedItem(picker, items) orelse return null;
    return item.source;
}

pub fn selectedItem(picker: *const app_prompt.RepoPickerState, items: []const Item) ?Item {
    const focused = picker.list.filter.list.focusedIndex();
    const item_index = picker.list.filter.sourceIndex(focused) orelse return null;
    if (item_index >= items.len) return null;
    return items[item_index];
}

pub fn insertCodepoint(picker: *app_prompt.RepoPickerState, codepoint: u21) EditResult {
    switch (picker.input_mode) {
        .list => return .none,
        .filter => {
            picker.list.resetNoMatch();
            picker.list.input.insert(codepoint) catch return .filter_too_long;
            return .refresh_filter;
        },
        .path_input => {
            picker.clearPathStatus();
            picker.path_input.insert(codepoint) catch {
                picker.path_error = .path_too_long;
                return .none;
            };
            return .path_changed;
        },
    }
}

pub fn insertSlice(picker: *app_prompt.RepoPickerState, text: []const u8) EditResult {
    switch (picker.input_mode) {
        .list => return .none,
        .filter => {
            picker.list.resetNoMatch();
            picker.list.input.insertSlice(text) catch return .filter_too_long;
            return .refresh_filter;
        },
        .path_input => {
            picker.clearPathStatus();
            picker.path_input.insertSlice(text) catch {
                picker.path_error = .path_too_long;
                return .none;
            };
            return .path_changed;
        },
    }
}

pub fn backspace(picker: *app_prompt.RepoPickerState) EditResult {
    switch (picker.input_mode) {
        .list => return .none,
        .filter => {
            picker.list.resetNoMatch();
            picker.list.input.backspace();
            return .refresh_filter;
        },
        .path_input => {
            picker.clearPathStatus();
            const previous_len = picker.path_input.len;
            picker.path_input.backspace();
            return if (picker.path_input.len != previous_len) .path_changed else .none;
        },
    }
}

pub fn moveLeft(picker: *app_prompt.RepoPickerState) void {
    switch (picker.input_mode) {
        .list => {},
        .filter => picker.list.input.moveLeft(),
        .path_input => picker.path_input.moveLeft(),
    }
}

pub fn moveRight(picker: *app_prompt.RepoPickerState) void {
    switch (picker.input_mode) {
        .list => {},
        .filter => picker.list.input.moveRight(),
        .path_input => picker.path_input.moveRight(),
    }
}

pub fn clearPathInput(picker: *app_prompt.RepoPickerState) void {
    picker.path_input.clear();
    picker.clearPathStatus();
}

pub fn hasPathInput(picker: *const app_prompt.RepoPickerState) bool {
    return std.mem.trim(u8, picker.path_input.slice(), " \t\r\n").len > 0;
}

pub fn listTitle(
    allocator: std.mem.Allocator,
    pending_discovery: ?repo_discovery.DiscoveryResult,
    active_discovery: ?repo_discovery.DiscoveryResult,
    recent: *const repo_state.RecentStore,
) ![]const u8 {
    if (pending_discovery) |discovery| {
        return switch (discovery) {
            .workspace => |workspace| try std.fmt.allocPrint(allocator, "Repositories in {s}", .{workspace.current_root}),
            .single_repo, .none => "Repositories",
        };
    }
    if (active_discovery) |discovery| {
        return switch (discovery) {
            .workspace => "Workspace repositories",
            .single_repo => if (recent.entries.items.len > 0) "Current and recent repositories" else "Current repository",
            .none => "Recent repositories",
        };
    }
    return "Recent repositories";
}

pub fn appendItem(allocator: std.mem.Allocator, items: *ItemList, label: []const u8, detail: []const u8, source: ItemSource) !void {
    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);
    const owned_detail = try allocator.dupe(u8, detail);
    errdefer allocator.free(owned_detail);
    try items.append(allocator, .{
        .label = owned_label,
        .detail = owned_detail,
        .source = source,
    });
}

pub fn clearItems(items: *ItemList, allocator: std.mem.Allocator) void {
    for (items.items) |*item| item.deinit(allocator);
    items.clearRetainingCapacity();
}

pub fn deinitItems(items: *ItemList, allocator: std.mem.Allocator) void {
    clearItems(items, allocator);
    items.deinit(allocator);
}

pub fn alreadyHasPath(
    pending_discovery: ?repo_discovery.DiscoveryResult,
    active_discovery: ?repo_discovery.DiscoveryResult,
    items: []const Item,
    path: []const u8,
) bool {
    if (pending_discovery) |discovery| {
        switch (discovery) {
            .workspace => |workspace| {
                if (std.mem.eql(u8, workspace.current_root, path)) return true;
                for (workspace.repos) |repo| {
                    if (std.mem.eql(u8, repo.canonical_root, path)) return true;
                }
            },
            .single_repo => |entry| if (std.mem.eql(u8, entry.canonical_root, path)) return true,
            .none => {},
        }
    }
    if (active_discovery) |discovery| {
        switch (discovery) {
            .workspace => |workspace| if (std.mem.eql(u8, workspace.current_root, path)) return true,
            .single_repo, .none => {},
        }
    }
    for (items) |item| {
        if (std.mem.eql(u8, item.detail, path)) return true;
    }
    return false;
}
