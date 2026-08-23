//! Domain-neutral strict, complete-input JSON mechanics.

const std = @import("std");

pub const Policy = struct {
    max_token_bytes: usize,
    max_depth: usize,
};

pub const ParseError = error{
    InvalidJson,
    DuplicateField,
    MissingField,
    InvalidType,
    InvalidValue,
    LimitExceeded,
} || std.mem.Allocator.Error;

/// Specialize the parser for one caller-owned finite policy.
pub fn Parser(comptime policy: Policy) type {
    if (policy.max_token_bytes == 0 or policy.max_depth == 0) {
        @compileError("strict JSON limits must be nonzero");
    }
    return struct {
        scanner: std.json.Scanner,
        allocator: std.mem.Allocator,
        depth: usize = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, bytes: []const u8) Self {
            return .{ .scanner = std.json.Scanner.initCompleteInput(allocator, bytes), .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.scanner.deinit();
            self.* = undefined;
        }

        pub fn beginObject(self: *Self) ParseError!void {
            if ((try self.next()) != .object_begin) return error.InvalidType;
        }

        pub fn beginArray(self: *Self) ParseError!void {
            if ((try self.next()) != .array_begin) return error.InvalidType;
        }

        pub fn nextObjectKey(self: *Self) ParseError!?[]const u8 {
            return switch (try self.next()) {
                .allocated_string => |value| value,
                .object_end => null,
                else => error.InvalidType,
            };
        }

        pub fn nextArrayObject(self: *Self) ParseError!bool {
            return switch (try self.next()) {
                .object_begin => true,
                .array_end => false,
                else => error.InvalidType,
            };
        }

        pub fn string(self: *Self) ParseError![]const u8 {
            return switch (try self.next()) {
                .allocated_string => |value| value,
                else => error.InvalidType,
            };
        }

        pub fn stringOrArrayEnd(self: *Self) ParseError!?[]const u8 {
            return switch (try self.next()) {
                .allocated_string => |value| value,
                .array_end => null,
                else => error.InvalidType,
            };
        }

        pub fn unsigned(self: *Self, comptime T: type) ParseError!T {
            const bytes = switch (try self.next()) {
                .allocated_number => |value| value,
                else => return error.InvalidType,
            };
            if (bytes.len == 0 or (bytes.len > 1 and bytes[0] == '0')) return error.InvalidValue;
            for (bytes) |byte| if (byte < '0' or byte > '9') return error.InvalidValue;
            return std.fmt.parseInt(T, bytes, 10) catch error.InvalidValue;
        }

        pub fn endDocument(self: *Self) ParseError!void {
            if ((try self.next()) != .end_of_document or self.depth != 0) return error.InvalidJson;
        }

        fn next(self: *Self) ParseError!std.json.Token {
            const token = self.scanner.nextAllocMax(self.allocator, .alloc_always, policy.max_token_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ValueTooLong => return error.LimitExceeded,
                error.SyntaxError, error.UnexpectedEndOfInput => return error.InvalidJson,
            };
            switch (token) {
                .object_begin, .array_begin => {
                    self.depth = std.math.add(usize, self.depth, 1) catch return error.LimitExceeded;
                    if (self.depth > policy.max_depth) return error.LimitExceeded;
                },
                .object_end, .array_end => {
                    if (self.depth == 0) return error.InvalidJson;
                    self.depth -= 1;
                },
                else => {},
            }
            return token;
        }
    };
}

pub fn markSeen(seen: *u32, bit: u5) ParseError!void {
    const mask = @as(u32, 1) << bit;
    if ((seen.* & mask) != 0) return error.DuplicateField;
    seen.* |= mask;
}

pub fn requireFields(seen: u32, required: u32) ParseError!void {
    if ((seen & required) != required) return error.MissingField;
}

const TestParser = Parser(.{ .max_token_bytes = 32, .max_depth = 2 });

test "neutral strict data field bookkeeping rejects duplicate and missing fields" {
    var seen: u32 = 0;
    try markSeen(&seen, 1);
    try std.testing.expectError(error.DuplicateField, markSeen(&seen, 1));
    try requireFields(seen, 0b10);
    try std.testing.expectError(error.MissingField, requireFields(seen, 0b11));
}

test "neutral strict data admits only canonical bounded unsigned integers" {
    const valid = [_][]const u8{ "0", "4294967295" };
    for (valid, 0..) |input, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = TestParser.init(arena.allocator(), input);
        defer parser.deinit();
        const value = try parser.unsigned(u32);
        try std.testing.expectEqual(if (index == 0) @as(u32, 0) else std.math.maxInt(u32), value);
        try parser.endDocument();
    }
    var leading_zero_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer leading_zero_arena.deinit();
    var leading_zero = TestParser.init(leading_zero_arena.allocator(), "01");
    defer leading_zero.deinit();
    try std.testing.expectEqual(@as(u32, 0), try leading_zero.unsigned(u32));
    try std.testing.expectError(error.InvalidJson, leading_zero.endDocument());

    for ([_][]const u8{ "-1", "1.0", "1e0", "4294967296" }) |input| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = TestParser.init(arena.allocator(), input);
        defer parser.deinit();
        try std.testing.expectError(error.InvalidValue, parser.unsigned(u32));
    }
}

test "neutral strict data enforces depth and one balanced complete document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var exact = TestParser.init(arena.allocator(), "[[0]]");
    defer exact.deinit();
    try exact.beginArray();
    try exact.beginArray();
    try std.testing.expectEqual(@as(u8, 0), try exact.unsigned(u8));
    try std.testing.expect((try exact.next()) == .array_end);
    try std.testing.expect((try exact.next()) == .array_end);
    try exact.endDocument();

    var deep = TestParser.init(arena.allocator(), "[[[0]]]");
    defer deep.deinit();
    try deep.beginArray();
    try deep.beginArray();
    try std.testing.expectError(error.LimitExceeded, deep.beginArray());

    for ([_][]const u8{ "{}{}", "[0" }) |input| {
        var parser = TestParser.init(arena.allocator(), input);
        defer parser.deinit();
        if (input[0] == '{') {
            try parser.beginObject();
            try std.testing.expect((try parser.nextObjectKey()) == null);
        } else {
            try parser.beginArray();
            _ = try parser.unsigned(u8);
        }
        try std.testing.expectError(error.InvalidJson, parser.endDocument());
    }
}

test "neutral strict data enforces decoded token bounds and Unicode syntax" {
    const TokenParser = Parser(.{ .max_token_bytes = 8, .max_depth = 1 });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var exact = TokenParser.init(arena.allocator(), "\"12345678\"");
    defer exact.deinit();
    try std.testing.expectEqualStrings("12345678", try exact.string());
    try exact.endDocument();

    var long = TokenParser.init(arena.allocator(), "\"123456789\"");
    defer long.deinit();
    try std.testing.expectError(error.LimitExceeded, long.string());

    var valid = TestParser.init(arena.allocator(), "\"\\ud83d\\ude00\"");
    defer valid.deinit();
    try std.testing.expectEqualStrings("😀", try valid.string());
    try valid.endDocument();
    var invalid = TestParser.init(arena.allocator(), "\"\\ud83d\"");
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidJson, invalid.string());
}
