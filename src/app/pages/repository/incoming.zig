//! Repository-owned half of contextual Review -> Repository navigation.
//!
//! The shell prepares `page_link.RepositoryIncoming` before page mutation.
//! `State.accept` is the allocation-free, infallible commit boundary: it
//! releases any previous owner and moves exactly one incoming arm into the
//! Repository page. The owner advances through explicit manifest and document
//! stages so async completions cannot apply a location after a newer browser
//! destination has won. Generation binding stays in this ownership model;
//! accepted-source inspection and line application remain page-owned.

const std = @import("std");
const page_link = @import("../../page_link.zig");

pub const AwaitingDocument = struct {
    location: page_link.RepositoryLocationIntent,
    manifest_revision: u64,
    document_generation: ?u64 = null,

    pub fn deinit(self: *AwaitingDocument, allocator: std.mem.Allocator) void {
        self.location.deinit(allocator);
        self.* = undefined;
    }
};

pub const State = union(enum) {
    none,
    awaiting_manifest: page_link.RepositoryLocationIntent,
    awaiting_document: AwaitingDocument,
    unavailable: page_link.RepositoryUnavailable,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .none => {},
            .awaiting_manifest => |*intent| intent.deinit(allocator),
            .awaiting_document => |*pending| pending.deinit(allocator),
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

    /// Move an exact manifest match into the document stage without copying
    /// its byte-exact path. The document stage binds the selected-file generation.
    pub fn advanceToDocument(self: *State, manifest_revision: u64) bool {
        const location = switch (self.*) {
            .awaiting_manifest => |location| location,
            .none, .awaiting_document, .unavailable => return false,
        };
        self.* = .{ .awaiting_document = .{
            .location = location,
            .manifest_revision = manifest_revision,
        } };
        return true;
    }

    /// Bind (or later rebind) the owner to the only selected-file completion
    /// allowed to consume it. Path and manifest identity are checked before
    /// the generation is recorded.
    pub fn bindDocumentGeneration(
        self: *State,
        manifest_revision: u64,
        path: []const u8,
        generation: u64,
    ) bool {
        const pending = switch (self.*) {
            .awaiting_document => |*pending| pending,
            .none, .awaiting_manifest, .unavailable => return false,
        };
        if (pending.manifest_revision != manifest_revision or
            !std.mem.eql(u8, pending.location.path, path)) return false;
        pending.document_generation = generation;
        return true;
    }

    /// Move a document-stage destination back to manifest authority before a
    /// reload/reactivation successor cycle. The byte-exact path owner and line
    /// hint are preserved; accepted revision/generation are deliberately
    /// discarded because neither can authorize the new cycle.
    pub fn restartManifestCycle(self: *State) bool {
        const location = switch (self.*) {
            .awaiting_document => |pending| pending.location,
            .none, .awaiting_manifest, .unavailable => return false,
        };
        self.* = .{ .awaiting_manifest = location };
        return true;
    }

    /// Consume a successfully resolved document owner and release its request
    /// path exactly once. The selected path/source remain Repository-owned.
    pub fn completeDocument(self: *State, allocator: std.mem.Allocator) bool {
        switch (self.*) {
            .awaiting_document => |*pending| pending.deinit(allocator),
            .none, .awaiting_manifest, .unavailable => return false,
        }
        self.* = .none;
        return true;
    }

    /// Convert a destination-known failure into the same owner used by a
    /// source-known direct-unavailable handoff. The path allocation is moved,
    /// never duplicated.
    pub fn terminalize(self: *State, reason: page_link.RepositoryUnavailableReason) bool {
        const intent = switch (self.*) {
            .awaiting_manifest => |intent| intent,
            .awaiting_document => |pending| pending.location,
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
        return switch (self.*) {
            .awaiting_manifest, .awaiting_document => true,
            .none, .unavailable => false,
        };
    }

    pub fn manifestIntent(self: *const State) ?*const page_link.RepositoryLocationIntent {
        return switch (self.*) {
            .awaiting_manifest => |*intent| intent,
            .none, .awaiting_document, .unavailable => null,
        };
    }

    pub fn documentIntent(self: *const State) ?*const AwaitingDocument {
        return switch (self.*) {
            .awaiting_document => |*pending| pending,
            .none, .awaiting_manifest, .unavailable => null,
        };
    }

    pub fn unavailableValue(self: *const State) ?*const page_link.RepositoryUnavailable {
        return switch (self.*) {
            .unavailable => |*unavailable| unavailable,
            .none, .awaiting_manifest, .awaiting_document => null,
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

test "Repository incoming advances exact manifest owner then terminalizes by move" {
    const allocator = std.testing.allocator;
    var state: State = .none;
    defer state.deinit(allocator);
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        7,
        .{ .device = 11, .inode = 13 },
        .{ .location = .{ .path = "src/main.zig", .line = 42 } },
    );
    state.accept(allocator, &incoming);
    const owned_address = @intFromPtr(state.awaiting_manifest.path.ptr);

    try std.testing.expect(state.advanceToDocument(9));
    try std.testing.expect(state.isPending());
    const pending = state.documentIntent().?;
    try std.testing.expectEqual(@as(u64, 9), pending.manifest_revision);
    try std.testing.expectEqual(@as(?u64, null), pending.document_generation);
    try std.testing.expectEqual(@as(?u32, 42), pending.location.line);
    try std.testing.expectEqual(owned_address, @intFromPtr(pending.location.path.ptr));
    try std.testing.expect(!state.advanceToDocument(10));

    try std.testing.expect(state.terminalize(.source_unavailable));
    try std.testing.expectEqual(owned_address, @intFromPtr(state.unavailable.path.ptr));
}

test "Repository incoming binds one document generation and completes owner" {
    const allocator = std.testing.allocator;
    var state: State = .none;
    defer state.deinit(allocator);
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        7,
        .{ .device = 11, .inode = 13 },
        .{ .location = .{ .path = "src/main.zig", .line = 42 } },
    );
    state.accept(allocator, &incoming);
    try std.testing.expect(state.advanceToDocument(9));

    try std.testing.expect(!state.bindDocumentGeneration(8, "src/main.zig", 3));
    try std.testing.expect(!state.bindDocumentGeneration(9, "src/other.zig", 3));
    try std.testing.expect(state.bindDocumentGeneration(9, "src/main.zig", 3));
    try std.testing.expectEqual(@as(?u64, 3), state.documentIntent().?.document_generation);
    try std.testing.expect(state.completeDocument(allocator));
    try std.testing.expect(state == .none);
    try std.testing.expect(!state.completeDocument(allocator));
}

test "Repository incoming restarts document owner at manifest authority" {
    const allocator = std.testing.allocator;
    var state: State = .none;
    defer state.deinit(allocator);
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        7,
        .{ .device = 11, .inode = 13 },
        .{ .location = .{ .path = "src/main.zig", .line = 42 } },
    );
    state.accept(allocator, &incoming);
    const owned_address = @intFromPtr(state.manifestIntent().?.path.ptr);
    try std.testing.expect(state.advanceToDocument(9));
    try std.testing.expect(state.bindDocumentGeneration(9, "src/main.zig", 3));

    try std.testing.expect(state.restartManifestCycle());
    try std.testing.expect(state == .awaiting_manifest);
    try std.testing.expectEqual(owned_address, @intFromPtr(state.manifestIntent().?.path.ptr));
    try std.testing.expectEqual(@as(?u32, 42), state.manifestIntent().?.line);
    try std.testing.expect(!state.restartManifestCycle());
}
