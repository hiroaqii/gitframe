const std = @import("std");
const ui = @import("chasen_ui");
const root_capability = @import("../repo/root_capability.zig");
pub const Scope = @import("../git/stash.zig").Scope;

pub const Snapshot = struct {
    repo_root: []u8,
    epoch: u64,
    identity: root_capability.Identity,
    branch: ?[]u8,
    oid: []u8,

    pub fn init(allocator: std.mem.Allocator, root: []const u8, epoch: u64, identity: root_capability.Identity, branch: ?[]const u8, oid: []const u8) !Snapshot {
        const owned_root = try allocator.dupe(u8, root);
        errdefer allocator.free(owned_root);
        const owned_branch = if (branch) |name| try allocator.dupe(u8, name) else null;
        errdefer if (owned_branch) |name| allocator.free(name);
        return .{ .repo_root = owned_root, .epoch = epoch, .identity = identity, .branch = owned_branch, .oid = try allocator.dupe(u8, oid) };
    }

    pub fn clone(self: Snapshot, allocator: std.mem.Allocator) !Snapshot {
        return init(allocator, self.repo_root, self.epoch, self.identity, self.branch, self.oid);
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        if (self.branch) |name| allocator.free(name);
        allocator.free(self.oid);
        self.* = undefined;
    }

    pub fn branchLabel(self: Snapshot, buffer: []u8) []const u8 {
        return self.branch orelse (std.fmt.bufPrint(buffer, "detached@{s}", .{self.oid[0..@min(12, self.oid.len)]}) catch "detached");
    }

    pub fn matchesTarget(self: Snapshot, branch: ?[]const u8, oid: []const u8) bool {
        if (self.branch) |name| return branch != null and std.mem.eql(u8, name, branch.?);
        return branch == null and std.mem.eql(u8, self.oid, oid);
    }
};

pub const Msg = union(enum) {
    open,
    cancel,
    confirm,
    tab,
    scope_previous,
    scope_next,
    text: ui.TextInput.Msg,
    /// Borrowed event bytes, consumed only by synchronous App.update.
    paste: []const u8,
};

pub const Create = struct {
    snapshot: Snapshot,
    message: ui.TextInput,
    scope: Scope = .all,
    focus: enum { scope, message } = .scope,

    pub fn deinit(self: *Create, allocator: std.mem.Allocator) void {
        self.snapshot.deinit(allocator);
        self.message.deinit();
        self.* = undefined;
    }

    pub fn edit(self: *Create, msg: ui.TextInput.Msg) !void {
        if (msg == .insert) {
            const cp = msg.insert;
            if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return;
            const width = std.unicode.utf8CodepointSequenceLength(cp) catch return;
            if (self.message.text().len + width > 512) return;
        }
        try self.message.update(msg);
    }

    pub fn paste(self: *Create, bytes: []const u8) !void {
        const view = std.unicode.Utf8View.init(bytes) catch return;
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            try self.edit(.{ .insert = if (cp == '\n' or cp == '\r' or cp == '\t') ' ' else cp });
        }
    }

    pub fn gitMessage(self: *const Create, allocator: std.mem.Allocator) ![]u8 {
        var branch_buffer: [96]u8 = undefined;
        const branch = self.snapshot.branchLabel(&branch_buffer);
        const message = std.mem.trim(u8, self.message.text(), " \t\r\n");
        return if (message.len == 0)
            std.fmt.allocPrint(allocator, "GitFrame [{s}]", .{branch})
        else
            std.fmt.allocPrint(allocator, "GitFrame [{s}]: {s}", .{ branch, message });
    }
};
