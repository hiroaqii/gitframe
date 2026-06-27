const std = @import("std");
const chasen = @import("chasen");

/// Draw text clipped to the available row width and mark truncation with "…".
///
/// This is a GitFrame-local helper shared by app chrome and diff metadata.
/// Scrollable diff body text intentionally uses a marker-free helper instead.
pub fn copyClippedTextAt(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, style: chasen.TextStyle) !void {
    const size = surface.size();
    if (col >= size.width) return;

    const clipped = chasen.text.clipToWidthWithMarker(text, size.width - col, "…");
    if (clipped.prefix.len > 0) {
        _ = try surface.copyTextAt(col, row, clipped.prefix, style);
    }
    if (clipped.marker.len > 0) {
        const marker_col = col + chasen.text.displayWidth(clipped.prefix);
        if (marker_col < size.width) {
            _ = try surface.copyTextAt(marker_col, row, clipped.marker, style);
        }
    }
}

/// Draw text clipped from the left so the filename/path tail remains visible.
///
/// Header paths are more useful when the basename survives clipping. The
/// marker is drawn at the left edge, followed by the tail that fits.
pub fn copyTailClippedTextAt(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, style: chasen.TextStyle) !void {
    const size = surface.size();
    if (col >= size.width) return;

    const available_width = size.width - col;
    const text_width = chasen.text.displayWidth(text);
    if (text_width <= available_width) {
        _ = try surface.copyTextAt(col, row, text, style);
        return;
    }

    const marker = "…/";
    const marker_width = chasen.text.displayWidth(marker);
    if (available_width <= marker_width) {
        const clipped = chasen.text.clipToWidth(marker, available_width);
        if (clipped.len > 0) _ = try surface.copyTextAt(col, row, clipped, style);
        return;
    }

    const tail_width = available_width - marker_width;
    var tail = chasen.text.dropToWidth(text, text_width - tail_width);
    if (std.mem.startsWith(u8, tail, "/") or std.mem.startsWith(u8, tail, "\\")) {
        tail = tail[1..];
    }
    _ = try surface.copyTextAt(col, row, marker, style);
    _ = try surface.copyTextAt(col + marker_width, row, tail, style);
}

/// Draw `prefix / path`, preserving the prefix while tail-clipping only path.
pub fn copyPrefixedTailClippedPathAt(surface: *chasen.Surface, col: u16, row: u16, prefix: ?[]const u8, path: []const u8, style: chasen.TextStyle) !void {
    const label = prefix orelse {
        try copyTailClippedTextAt(surface, col, row, path, style);
        return;
    };
    if (label.len == 0) {
        try copyTailClippedTextAt(surface, col, row, path, style);
        return;
    }

    const size = surface.size();
    if (col >= size.width) return;

    const separator = " / ";
    const label_width = chasen.text.displayWidth(label);
    const separator_width = chasen.text.displayWidth(separator);
    const reserved_width = label_width + separator_width;
    const available_width = size.width - col;
    if (reserved_width >= available_width) {
        try copyClippedTextAt(surface, col, row, label, style);
        return;
    }

    _ = try surface.copyTextAt(col, row, label, style);
    _ = try surface.copyTextAt(col + label_width, row, separator, style);
    var path_surface = surface.child(.{
        .col = @intCast(col + reserved_width),
        .row = row,
        .width = @intCast(available_width - reserved_width),
        .height = 1,
    });
    try copyTailClippedTextAt(&path_surface, 0, 0, path, style);
}

test "copyClippedTextAt draws text within width" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(8, 1);
    defer ts.deinit();

    try copyClippedTextAt(&ts.surface, 0, 0, "abc", .{});

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "abc") != null);
}

test "copyClippedTextAt marks truncated text" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(4, 1);
    defer ts.deinit();

    try copyClippedTextAt(&ts.surface, 0, 0, "abcdef", .{});

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "…") != null);
}

test "copyClippedTextAt does nothing when column is outside surface" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(4, 1);
    defer ts.deinit();

    try copyClippedTextAt(&ts.surface, 4, 0, "abc", .{});

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "abc") == null);
}

test "copyClippedTextAt clips by display width" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(4, 1);
    defer ts.deinit();

    try copyClippedTextAt(&ts.surface, 0, 0, "あいう", .{});

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "…") != null);
}

test "copyClippedTextAt skips marker when marker column is outside surface" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(1, 1);
    defer ts.deinit();

    try copyClippedTextAt(&ts.surface, 0, 0, "abcdef", .{});

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(chasen.text.displayWidth(snapshot) <= 1);
}

test "copyTailClippedTextAt keeps tail visible" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(18, 1);
    defer ts.deinit();

    try copyTailClippedTextAt(&ts.surface, 0, 0, "gitframe / very/deep/example.zig", .{});

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "…/") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "example.zig") != null);
}

test "copyTailClippedTextAt avoids duplicate path separator after marker" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(14, 1);
    defer ts.deinit();

    try copyTailClippedTextAt(&ts.surface, 0, 0, "very/deep/example.zig", .{});

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "…//") == null);
}

test "copyPrefixedTailClippedPathAt preserves prefix and filename tail" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(24, 1);
    defer ts.deinit();

    try copyPrefixedTailClippedPathAt(&ts.surface, 0, 0, "gitframe", "very/deep/path/example.zig", .{});

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "gitframe / ") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "…/example.zig") != null);
}
