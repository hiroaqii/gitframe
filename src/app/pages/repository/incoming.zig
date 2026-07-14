//! Repository-owned half of contextual Review -> Repository navigation.
//!
//! The shell prepares `page_link.RepositoryIncoming` before page mutation.
//! `State.accept` is the allocation-free, infallible commit boundary: it
//! releases any previous owner and moves exactly one incoming arm into the
//! Repository page. Manifest/document resolution is added by the next slice;
//! this module first closes direct-unavailable presentation and every owner
//! terminal that does not depend on async request generations.

const std = @import("std");
const page_link = @import("../../page_link.zig");

pub const State = union(enum) {
    none,
    awaiting_manifest: page_link.RepositoryLocationIntent,
    unavailable: page_link.RepositoryUnavailable,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .none => {},
            .awaiting_manifest => |*intent| intent.deinit(allocator),
            .unavailable => |*unavailable| unavailable.deinit(allocator),
        }
        self.* = .none;
    }

    /// Move a shell-prepared owner into Repository without allocation or an
    /// error edge. The caller must treat `incoming` as consumed afterwards.
    pub fn accept(self: *State, allocator: std.mem.Allocator, incoming: *page_link.RepositoryIncoming) void {
        self.deinit(allocator);
        const moved = incoming.*;
        incoming.* = undefined;
        self.* = switch (moved) {
            .no_context => .none,
            .location => |intent| .{ .awaiting_manifest = intent },
            .unavailable => |unavailable| .{ .unavailable = unavailable },
        };
    }

    /// Convert a destination-known failure into the same owner used by a
    /// source-known direct-unavailable handoff. The path allocation is moved,
    /// never duplicated.
    pub fn terminalize(self: *State, reason: page_link.RepositoryUnavailableReason) bool {
        const intent = switch (self.*) {
            .awaiting_manifest => |intent| intent,
            .none, .unavailable => return false,
        };
        self.* = .{ .unavailable = .{
            .repo_epoch = intent.repo_epoch,
            .root_identity = intent.root_identity,
            .path = intent.path,
            .reason = reason,
        } };
        return true;
    }

    pub fn dismiss(self: *State, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }

    pub fn isPending(self: *const State) bool {
        return self.* == .awaiting_manifest;
    }

    pub fn unavailableValue(self: *const State) ?*const page_link.RepositoryUnavailable {
        return switch (self.*) {
            .unavailable => |*unavailable| unavailable,
            .none, .awaiting_manifest => null,
        };
    }
};

test "Repository incoming state replaces owners and no context dismisses" {
    const allocator = std.testing.allocator;
    var state: State = .none;
    defer state.deinit(allocator);

    var first = try page_link.RepositoryIncoming.initOwned(
        allocator,
        1,
        .{ .device = 2, .inode = 3 },
        .{ .location = .{ .path = "first.zig", .line = 4 } },
    );
    state.accept(allocator, &first);
    try std.testing.expect(state == .awaiting_manifest);
    try std.testing.expectEqualStrings("first.zig", state.awaiting_manifest.path);

    var second = try page_link.RepositoryIncoming.initOwned(
        allocator,
        5,
        .{ .device = 8, .inode = 13 },
        .{ .unavailable = .{ .path = "deleted.zig", .reason = .no_current_path } },
    );
    state.accept(allocator, &second);
    try std.testing.expect(state == .unavailable);
    try std.testing.expectEqualStrings("deleted.zig", state.unavailable.path);
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.no_current_path, state.unavailable.reason);

    var no_context = try page_link.RepositoryIncoming.initOwned(
        allocator,
        5,
        .{ .device = 8, .inode = 13 },
        .no_context,
    );
    state.accept(allocator, &no_context);
    try std.testing.expect(state == .none);
}

test "Repository incoming terminal moves byte-exact path without allocation" {
    const allocator = std.testing.allocator;
    var state: State = .none;
    defer state.deinit(allocator);
    const raw_path = [_]u8{ 'o', 'l', 'd', '/', 0xff };
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        7,
        .{ .device = 11, .inode = 13 },
        .{ .location = .{ .path = &raw_path, .line = null } },
    );
    state.accept(allocator, &incoming);
    const owned_address = @intFromPtr(state.awaiting_manifest.path.ptr);

    try std.testing.expect(state.terminalize(.path_not_found));
    try std.testing.expectEqual(owned_address, @intFromPtr(state.unavailable.path.ptr));
    try std.testing.expectEqualSlices(u8, &raw_path, state.unavailable.path);
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.path_not_found, state.unavailable.reason);
    try std.testing.expect(!state.terminalize(.request_failed));
}
