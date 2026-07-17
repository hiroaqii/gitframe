//! One-shot Repository file-search focus handoff authority.
//!
//! A successful file search cannot focus the source pane until the selected
//! document is accepted. This state records either the exact Repository basis
//! waiting for request preparation or the one document generation allowed to
//! complete that handoff. It never decides whether a source completion is
//! acceptable; the page's existing document admission gate remains the sole
//! content authority and calls this state only after acceptance.
//!
//! `Basis.path` borrows the selected path owned by the accepted Repository
//! manifest. The page must clear this state before replacing that manifest or
//! mutating the selected path. Keeping the state allocation-free makes the
//! file-search selection commit infallible and avoids a parallel path owner.

const std = @import("std");
const root_capability = @import("../../../repo/root_capability.zig");

pub const Basis = struct {
    repo_epoch: u64,
    activation_id: u64,
    root_identity: root_capability.Identity,
    manifest_revision: u64,
    path: []const u8,

    pub fn eql(self: Basis, other: Basis) bool {
        return self.repo_epoch == other.repo_epoch and
            self.activation_id == other.activation_id and
            self.root_identity.eql(other.root_identity) and
            self.manifest_revision == other.manifest_revision and
            std.mem.eql(u8, self.path, other.path);
    }
};

pub const BoundGeneration = struct {
    basis: Basis,
    generation: u64,
};

/// Page-owned description of the request currently named by
/// `pending_document_generation`. Keeping basis and generation in one value
/// prevents R.2c from pairing a newer path basis with an older pending scalar.
pub const PendingDocumentRequest = struct {
    basis: Basis,
    generation: u64,
};

pub const State = union(enum) {
    none,
    awaiting_document_request: Basis,
    awaiting_document_generation: BoundGeneration,

    pub fn clear(self: *State) void {
        self.* = .none;
    }

    /// Install the allocation-free state used when the accepting transaction
    /// has no compatible request yet. Request preparation must later present
    /// the same exact basis before it may bind a generation.
    pub fn awaitDocumentRequest(self: *State, basis: Basis) void {
        self.* = .{ .awaiting_document_request = basis };
    }

    /// Bind the request prepared after file-search acceptance. An incompatible
    /// preparation supersedes and clears the old intent; it must not leave an
    /// unbound state which no future completion can consume.
    pub fn bindPrepared(self: *State, pending: PendingDocumentRequest) bool {
        const awaiting = switch (self.*) {
            .awaiting_document_request => |awaiting| awaiting,
            .none, .awaiting_document_generation => {
                self.clear();
                return false;
            },
        };
        if (pending.generation == 0 or !awaiting.eql(pending.basis)) {
            self.clear();
            return false;
        }
        self.* = .{
            .awaiting_document_generation = .{
                // Retain the manifest-owned path installed by submit. The
                // pending basis may describe an independently owned request
                // path whose storage moves into the task and is later freed.
                .basis = awaiting,
                .generation = pending.generation,
            },
        };
        return true;
    }

    /// Directly bind a request which was already pending when search submit
    /// committed the same path. Current and pending authority are supplied
    /// independently so a merely non-null or stale generation cannot authorize
    /// focus.
    pub fn bindExisting(
        self: *State,
        current_basis: Basis,
        current_generation: u64,
        pending: PendingDocumentRequest,
    ) bool {
        self.clear();
        if (current_generation == 0 or
            pending.generation == 0 or
            current_generation != pending.generation or
            !current_basis.eql(pending.basis)) return false;
        self.* = .{ .awaiting_document_generation = .{
            .basis = current_basis,
            .generation = current_generation,
        } };
        return true;
    }

    /// Consume only after the page has accepted a source for this exact basis
    /// and generation. An older or otherwise unrelated completion cannot clear
    /// a newer handoff.
    pub fn consumeAccepted(self: *State, basis: Basis, generation: u64) bool {
        const bound = switch (self.*) {
            .awaiting_document_generation => |bound| bound,
            .none, .awaiting_document_request => return false,
        };
        if (bound.generation != generation or !bound.basis.eql(basis)) return false;
        self.clear();
        return true;
    }

    /// Clear a non-accepting terminal only when it owns the currently bound
    /// generation. Wrong/older generation failures leave the successor intact.
    pub fn clearGeneration(self: *State, generation: u64) bool {
        const bound = switch (self.*) {
            .awaiting_document_generation => |bound| bound,
            .none, .awaiting_document_request => return false,
        };
        if (bound.generation != generation) return false;
        self.clear();
        return true;
    }

    pub fn awaitingRequest(self: *const State) ?Basis {
        return switch (self.*) {
            .awaiting_document_request => |basis| basis,
            .none, .awaiting_document_generation => null,
        };
    }

    pub fn awaitingGeneration(self: *const State) ?BoundGeneration {
        return switch (self.*) {
            .awaiting_document_generation => |bound| bound,
            .none, .awaiting_document_request => null,
        };
    }
};

fn testBasis(path: []const u8) Basis {
    return .{
        .repo_epoch = 3,
        .activation_id = 5,
        .root_identity = .{ .device = 8, .inode = 13 },
        .manifest_revision = 21,
        .path = path,
    };
}

test "repository file search focus basis covers exact Repository authority" {
    const basis = testBasis("src/main.zig");

    var changed = basis;
    changed.repo_epoch += 1;
    try std.testing.expect(!basis.eql(changed));
    changed = basis;
    changed.activation_id += 1;
    try std.testing.expect(!basis.eql(changed));
    changed = basis;
    changed.root_identity.device += 1;
    try std.testing.expect(!basis.eql(changed));
    changed = basis;
    changed.manifest_revision += 1;
    try std.testing.expect(!basis.eql(changed));
    changed = basis;
    changed.path = "src/other.zig";
    try std.testing.expect(!basis.eql(changed));
}

test "repository file search focus binds prepared generation and consumes exact acceptance" {
    const selected_path = "src/main.zig";
    const basis = testBasis(selected_path);
    var state: State = .none;
    state.awaitDocumentRequest(basis);
    try std.testing.expect(state.awaitingRequest().?.eql(basis));
    var request_path = [_]u8{ 's', 'r', 'c', '/', 'm', 'a', 'i', 'n', '.', 'z', 'i', 'g' };
    const request_basis = testBasis(&request_path);
    try std.testing.expect(state.bindPrepared(.{ .basis = request_basis, .generation = 34 }));
    try std.testing.expectEqual(@as(u64, 34), state.awaitingGeneration().?.generation);
    try std.testing.expectEqual(@intFromPtr(selected_path.ptr), @intFromPtr(state.awaitingGeneration().?.basis.path.ptr));

    var wrong_basis = basis;
    wrong_basis.manifest_revision += 1;
    try std.testing.expect(!state.consumeAccepted(wrong_basis, 34));
    try std.testing.expect(!state.consumeAccepted(basis, 33));
    try std.testing.expectEqual(@as(u64, 34), state.awaitingGeneration().?.generation);

    try std.testing.expect(state.consumeAccepted(basis, 34));
    try std.testing.expect(state == .none);
}

test "repository file search focus incompatible preparation clears unbound intent" {
    const basis = testBasis("src/main.zig");
    var state: State = .none;
    state.awaitDocumentRequest(basis);

    var wrong_path = basis;
    wrong_path.path = "src/other.zig";
    try std.testing.expect(!state.bindPrepared(.{ .basis = wrong_path, .generation = 34 }));
    try std.testing.expect(state == .none);

    state.awaitDocumentRequest(basis);
    try std.testing.expect(!state.bindPrepared(.{ .basis = basis, .generation = 0 }));
    try std.testing.expect(state == .none);

    try std.testing.expect(state.bindExisting(basis, 34, .{ .basis = basis, .generation = 34 }));
    try std.testing.expect(!state.bindPrepared(.{ .basis = basis, .generation = 35 }));
    try std.testing.expect(state == .none);
}

test "repository file search focus direct bind requires exact pending basis" {
    const raw_path = [_]u8{ 's', 'r', 'c', '/', 0xff, '.', 'z', 'i', 'g' };
    const basis = testBasis(&raw_path);
    var state: State = .none;

    var wrong_root = basis;
    wrong_root.root_identity.inode += 1;
    try std.testing.expect(!state.bindExisting(basis, 55, .{ .basis = wrong_root, .generation = 55 }));
    try std.testing.expect(state == .none);

    var equal_bytes = raw_path;
    const pending_basis = testBasis(&equal_bytes);
    try std.testing.expect(!state.bindExisting(basis, 56, .{ .basis = pending_basis, .generation = 55 }));
    try std.testing.expect(state == .none);

    try std.testing.expect(state.bindExisting(basis, 55, .{ .basis = pending_basis, .generation = 55 }));
    try std.testing.expectEqualSlices(u8, &raw_path, state.awaitingGeneration().?.basis.path);
    try std.testing.expectEqual(@as(u64, 55), state.awaitingGeneration().?.generation);
}

test "repository file search focus terminal clears only exact bound generation" {
    const basis = testBasis("main.zig");
    var state: State = .none;
    try std.testing.expect(state.bindExisting(basis, 89, .{ .basis = basis, .generation = 89 }));

    try std.testing.expect(!state.clearGeneration(88));
    try std.testing.expectEqual(@as(u64, 89), state.awaitingGeneration().?.generation);
    try std.testing.expect(state.clearGeneration(89));
    try std.testing.expect(state == .none);
}
