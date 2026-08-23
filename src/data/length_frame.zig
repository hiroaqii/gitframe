//! Allocation-free checked framing for one JSON header and one or two payloads.

const std = @import("std");
pub const Limits = struct { max_header_bytes: usize, max_payload_bytes: usize };
pub const Parts = struct { header: []const u8, payload: []const u8 };
pub const PayloadPair = struct { first: []const u8, second: []const u8 };
pub const Error = error{ InvalidFrame, HeaderTooLarge, PayloadTooLarge, LengthMismatch, LengthOverflow };
pub fn split(input: []const u8, limits: Limits) Error!Parts {
    const lf = std.mem.indexOfScalar(u8, input, '\n') orelse return error.InvalidFrame;
    if (lf == 0) return error.InvalidFrame;
    const payload_start = std.math.add(usize, lf, 1) catch return error.LengthOverflow;
    if (payload_start > limits.max_header_bytes) return error.HeaderTooLarge;
    const payload = input[payload_start..];
    if (payload.len > limits.max_payload_bytes) return error.PayloadTooLarge;
    return .{ .header = input[0..lf], .payload = payload };
}
pub fn exactPayload(parts: Parts, claimed_size: usize) Error![]const u8 {
    if (parts.payload.len != claimed_size) return error.LengthMismatch;
    return parts.payload;
}
pub fn exactPayloadPair(parts: Parts, first_size: usize, second_size: usize) Error!PayloadPair {
    const total = std.math.add(usize, first_size, second_size) catch return error.LengthOverflow;
    if (parts.payload.len != total) return error.LengthMismatch;
    return .{ .first = parts.payload[0..first_size], .second = parts.payload[first_size..] };
}
test "neutral length frame splits first LF and preserves binary payload" {
    const parts = try split("header\n\x00a\n\xff", .{ .max_header_bytes = 7, .max_payload_bytes = 4 });
    try std.testing.expectEqualStrings("header", parts.header);
    try std.testing.expectEqualSlices(u8, "\x00a\n\xff", parts.payload);
}

test "neutral length frame enforces separator header and payload limits" {
    try std.testing.expectError(error.InvalidFrame, split("header", .{ .max_header_bytes = 7, .max_payload_bytes = 0 }));
    try std.testing.expectError(error.InvalidFrame, split("\npayload", .{ .max_header_bytes = 1, .max_payload_bytes = 7 }));
    _ = try split("head\nbody", .{ .max_header_bytes = 5, .max_payload_bytes = 4 });
    try std.testing.expectError(error.HeaderTooLarge, split("head\n", .{ .max_header_bytes = 4, .max_payload_bytes = 0 }));
    try std.testing.expectError(error.PayloadTooLarge, split("head\nbody", .{ .max_header_bytes = 5, .max_payload_bytes = 3 }));
}

test "neutral length frame admits only exact one payload including zero" {
    const parts = try split("h\nabc", .{ .max_header_bytes = 2, .max_payload_bytes = 3 });
    try std.testing.expectEqualStrings("abc", try exactPayload(parts, 3));
    try std.testing.expectError(error.LengthMismatch, exactPayload(parts, 2));
    try std.testing.expectError(error.LengthMismatch, exactPayload(parts, 4));
    const empty = try split("h\n", .{ .max_header_bytes = 2, .max_payload_bytes = 0 });
    try std.testing.expectEqual(@as(usize, 0), (try exactPayload(empty, 0)).len);
}

test "neutral length frame admits exact pair and rejects overflow" {
    const parts = try split("h\na\x00\xff", .{ .max_header_bytes = 2, .max_payload_bytes = 3 });
    const pair = try exactPayloadPair(parts, 1, 2);
    try std.testing.expectEqualSlices(u8, "a", pair.first);
    try std.testing.expectEqualSlices(u8, "\x00\xff", pair.second);
    try std.testing.expectError(error.LengthMismatch, exactPayloadPair(parts, 1, 1));
    try std.testing.expectError(error.LengthMismatch, exactPayloadPair(parts, 1, 3));
    try std.testing.expectError(error.LengthOverflow, exactPayloadPair(parts, std.math.maxInt(usize), 1));
    const empty = try split("h\n", .{ .max_header_bytes = 2, .max_payload_bytes = 0 });
    _ = try exactPayloadPair(empty, 0, 0);
}
