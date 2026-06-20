const std = @import("std");
const loaded_diff = @import("../loaded_diff.zig");

pub const OverlayKind = enum {
    none,
    help,
};

/// App-owned modal/overlay state.
///
/// Overlay-specific viewport state lives with the overlay selector so opening,
/// closing, and future overlays do not add more primitive fields to `App`.
pub const OverlayState = struct {
    kind: OverlayKind = .none,
    help_scroll: usize = 0,

    pub fn isHelp(self: OverlayState) bool {
        return self.kind == .help;
    }

    pub fn openHelp(self: *OverlayState) void {
        self.kind = .help;
        self.help_scroll = 0;
    }

    pub fn close(self: *OverlayState) void {
        self.kind = .none;
    }
};

/// Short-lived status text shown in the shell header.
///
/// Store the length instead of a slice into `buf`. That keeps the value
/// self-contained even if App state is copied in tests or future snapshots.
pub const StatusMessage = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *StatusMessage, comptime fmt: []const u8, args: anytype) void {
        const formatted = std.fmt.bufPrint(&self.buf, fmt, args) catch "status formatting failed";
        self.len = formatted.len;
    }

    pub fn text(self: *const StatusMessage) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Display-only review filters applied to the active loaded diff.
///
/// The reviewed store remains the source of truth; this state only controls
/// how the active sidebar projection is filtered.
pub const ReviewDisplayState = struct {
    hide_reviewed_files: bool = false,
    changed_file_filter: loaded_diff.ChangedFileFilter = .all,
};

/// Pending selection restore across a Git action triggered reload.
///
/// Git actions can move a file between diff/status projections. Keep the
/// logical path and previous visible row outside the load arena so the next
/// accepted load can restore the user's review position.
pub const PendingSelectionRestore = struct {
    path_key: []u8,
    visible_row: usize,

    pub fn deinit(self: *PendingSelectionRestore, allocator: std.mem.Allocator) void {
        allocator.free(self.path_key);
        self.* = undefined;
    }
};

test "OverlayState opens help and resets its scroll" {
    var overlay: OverlayState = .{ .kind = .help, .help_scroll = 5 };

    overlay.close();
    try std.testing.expectEqual(OverlayKind.none, overlay.kind);
    try std.testing.expectEqual(@as(usize, 5), overlay.help_scroll);

    overlay.openHelp();
    try std.testing.expectEqual(OverlayKind.help, overlay.kind);
    try std.testing.expectEqual(@as(usize, 0), overlay.help_scroll);
}

test "StatusMessage owns its formatted text buffer" {
    var status: StatusMessage = .{};

    status.set("loaded {d}", .{3});

    try std.testing.expectEqualStrings("loaded 3", status.text());
}

test "StatusMessage remains self-contained after value copy" {
    var status: StatusMessage = .{};
    status.set("loaded {d}", .{3});

    const copied = status;

    try std.testing.expectEqualStrings("loaded 3", copied.text());
}
