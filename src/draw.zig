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
