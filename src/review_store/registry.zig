//! Strict bounded read-only codec for the machine-local repository registry.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const strict = @import("../committed_review/strict_json.zig");
const capability = @import("capability.zig");
const store_path = @import("path.zig");

pub const max_registry_bytes: usize = 1024 * 1024;
pub const max_bindings: usize = 4096;

pub const PathEncoding = enum { utf8, base64 };

pub const DiagnosticPath = struct {
    encoding: PathEncoding,
    bytes: []const u8,
};

/// Choose the one canonical lossless registry representation for diagnostic
/// path bytes. The returned slice continues to borrow `bytes`.
pub fn diagnosticPath(bytes: []const u8) strict.ParseError!DiagnosticPath {
    store_path.validateAbsoluteCanonical(bytes) catch return error.InvalidValue;
    return .{
        .encoding = if (isPrintableUtf8(bytes)) .utf8 else .base64,
        .bytes = bytes,
    };
}

pub const Binding = struct {
    review_repository_id: committed_review.ReviewRepositoryId,
    locator: committed_review.GitCommonDirectoryLocator,
    canonical_path: DiagnosticPath,
    last_seen_path: DiagnosticPath,
};

pub const ParsedRegistry = struct {
    arena: std.heap.ArenaAllocator,
    bindings: []const Binding,

    pub fn deinit(self: *ParsedRegistry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn lookup(
        self: *const ParsedRegistry,
        locator: committed_review.GitCommonDirectoryLocator,
    ) ?committed_review.ReviewRepositoryId {
        for (self.bindings) |binding| {
            if (binding.locator.eql(locator)) return binding.review_repository_id;
        }
        return null;
    }
};

pub const ReadResult = union(enum) {
    missing,
    registry: ParsedRegistry,
    invalid,
    unavailable: enum { permission_denied, io_failed },

    pub fn deinit(self: *ReadResult) void {
        switch (self.*) {
            .registry => |*value| value.deinit(),
            .missing, .invalid, .unavailable => {},
        }
        self.* = .missing;
    }
};

pub fn read(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: capability.DirectoryCapability,
) std.mem.Allocator.Error!ReadResult {
    const bytes = root.readRegularAlloc(allocator, io, "registry.json", max_registry_bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return classifyReadError(err);
    };
    defer allocator.free(bytes);
    return .{ .registry = parseStrict(allocator, bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .invalid;
    } };
}

fn classifyReadError(err: anyerror) ReadResult {
    return switch (err) {
        error.FileNotFound => .missing,
        error.AccessDenied, error.PermissionDenied => .{ .unavailable = .permission_denied },
        error.WrongType, error.WrongOwner, error.WrongMode, error.CrossDevice, error.MultipleLinks, error.SymLinkLoop, error.NotDir, error.FileSizeOutOfBounds, error.FileChangedWhileReading => .invalid,
        else => .{ .unavailable = .io_failed },
    };
}

pub fn parseStrict(allocator: std.mem.Allocator, bytes: []const u8) strict.ParseError!ParsedRegistry {
    if (bytes.len == 0 or bytes.len > max_registry_bytes) return error.ArtifactTooLarge;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    var parser = strict.Parser.init(arena_allocator, bytes);
    defer parser.deinit();

    try parser.beginObject();
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var bindings: ?[]const Binding = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            try strict.markSeen(&seen, 0);
            schema_version = try parser.unsigned(u64);
        } else if (std.mem.eql(u8, key, "bindings")) {
            try strict.markSeen(&seen, 1);
            bindings = try parseBindings(&parser, arena_allocator);
        } else {
            return error.UnknownField;
        }
    }
    try strict.requireFields(seen, 0b11);
    if (schema_version.? != 1) return error.UnsupportedSchemaVersion;
    try parser.endDocument();
    const canonical = try writeCanonicalAlloc(allocator, bindings.?);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) return error.InvalidValue;
    return .{ .arena = arena, .bindings = bindings.? };
}

/// Pure canonical codec shared with the later registry mutation owner. It
/// performs no filesystem operation and fixes field order, scalar spelling,
/// compactness, and the final LF.
pub fn writeCanonicalAlloc(
    allocator: std.mem.Allocator,
    bindings: []const Binding,
) strict.ParseError![]u8 {
    if (bindings.len > max_bindings) return error.LimitExceeded;
    for (bindings, 0..) |binding, index| {
        const repository_id = binding.review_repository_id.canonical();
        _ = committed_review.ReviewRepositoryId.parse(&repository_id) catch return error.InvalidValue;
        for (bindings[0..index]) |prior| {
            if (prior.review_repository_id.eql(binding.review_repository_id)) return error.InvalidValue;
        }
        if (index != 0) {
            const prior = bindings[index - 1].locator;
            if (prior.device > binding.locator.device or
                (prior.device == binding.locator.device and prior.inode >= binding.locator.inode))
            {
                return error.InvalidValue;
            }
        }
    }
    const buffer = try allocator.alloc(u8, max_registry_bytes);
    errdefer allocator.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch return error.ArtifactTooLarge;
    stringify.objectField("schema_version") catch return error.ArtifactTooLarge;
    stringify.write(@as(u64, 1)) catch return error.ArtifactTooLarge;
    stringify.objectField("bindings") catch return error.ArtifactTooLarge;
    stringify.beginArray() catch return error.ArtifactTooLarge;
    for (bindings) |binding| {
        stringify.beginObject() catch return error.ArtifactTooLarge;
        const repository_id = binding.review_repository_id.canonical();
        try jsonField(&stringify, "review_repository_id", &repository_id);
        var device_buffer: [20]u8 = undefined;
        const device = std.fmt.bufPrint(&device_buffer, "{d}", .{binding.locator.device}) catch
            return error.InvalidValue;
        try jsonField(&stringify, "device", device);
        var inode_buffer: [20]u8 = undefined;
        const inode = std.fmt.bufPrint(&inode_buffer, "{d}", .{binding.locator.inode}) catch
            return error.InvalidValue;
        try jsonField(&stringify, "inode", inode);
        try writeDiagnosticPath(&stringify, "canonical_path", binding.canonical_path, allocator);
        try writeDiagnosticPath(&stringify, "last_seen_path", binding.last_seen_path, allocator);
        stringify.endObject() catch return error.ArtifactTooLarge;
    }
    stringify.endArray() catch return error.ArtifactTooLarge;
    stringify.endObject() catch return error.ArtifactTooLarge;
    writer.writeByte('\n') catch return error.ArtifactTooLarge;
    return try allocator.realloc(buffer, writer.buffered().len);
}

fn jsonField(stringify: *std.json.Stringify, name: []const u8, value: []const u8) strict.ParseError!void {
    stringify.objectField(name) catch return error.ArtifactTooLarge;
    stringify.write(value) catch return error.ArtifactTooLarge;
}

fn writeDiagnosticPath(
    stringify: *std.json.Stringify,
    field_name: []const u8,
    path: DiagnosticPath,
    allocator: std.mem.Allocator,
) strict.ParseError!void {
    store_path.validateAbsoluteCanonical(path.bytes) catch return error.InvalidValue;
    stringify.objectField(field_name) catch return error.ArtifactTooLarge;
    stringify.beginObject() catch return error.ArtifactTooLarge;
    try jsonField(stringify, "encoding", @tagName(path.encoding));
    switch (path.encoding) {
        .utf8 => {
            if (!std.unicode.utf8ValidateSlice(path.bytes)) return error.InvalidValue;
            try strict.validateText(path.bytes, store_path.max_store_root_bytes, false);
            try jsonField(stringify, "value", path.bytes);
        },
        .base64 => {
            if (isPrintableUtf8(path.bytes)) return error.InvalidValue;
            const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(path.bytes.len));
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, path.bytes);
            try jsonField(stringify, "value", encoded);
        },
    }
    stringify.endObject() catch return error.ArtifactTooLarge;
}

fn parseBindings(parser: *strict.Parser, allocator: std.mem.Allocator) strict.ParseError![]const Binding {
    try parser.beginArray();
    var values: std.ArrayList(Binding) = .empty;
    while (try parser.nextArrayObject()) {
        if (values.items.len == max_bindings) return error.LimitExceeded;
        const value = try parseBindingBody(parser, allocator);
        for (values.items) |prior| {
            if (prior.locator.eql(value.locator) or
                prior.review_repository_id.eql(value.review_repository_id)) return error.InvalidValue;
        }
        if (values.items.len != 0) {
            const prior = values.items[values.items.len - 1].locator;
            if (prior.device > value.locator.device or
                (prior.device == value.locator.device and prior.inode >= value.locator.inode))
            {
                return error.InvalidValue;
            }
        }
        try values.append(allocator, value);
    }
    return try values.toOwnedSlice(allocator);
}

fn parseBindingBody(parser: *strict.Parser, allocator: std.mem.Allocator) strict.ParseError!Binding {
    var seen: u32 = 0;
    var repository_id: ?committed_review.ReviewRepositoryId = null;
    var device: ?u64 = null;
    var inode: ?u64 = null;
    var canonical_path: ?DiagnosticPath = null;
    var last_seen_path: ?DiagnosticPath = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "review_repository_id")) {
            try strict.markSeen(&seen, 0);
            repository_id = committed_review.ReviewRepositoryId.parse(try parser.string()) catch
                return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "device")) {
            try strict.markSeen(&seen, 1);
            device = try parseDecimal(try parser.string());
        } else if (std.mem.eql(u8, key, "inode")) {
            try strict.markSeen(&seen, 2);
            inode = try parseDecimal(try parser.string());
        } else if (std.mem.eql(u8, key, "canonical_path")) {
            try strict.markSeen(&seen, 3);
            canonical_path = try parsePath(parser, allocator);
        } else if (std.mem.eql(u8, key, "last_seen_path")) {
            try strict.markSeen(&seen, 4);
            last_seen_path = try parsePath(parser, allocator);
        } else {
            return error.UnknownField;
        }
    }
    try strict.requireFields(seen, 0b1_1111);
    return .{
        .review_repository_id = repository_id.?,
        .locator = .{ .device = device.?, .inode = inode.? },
        .canonical_path = canonical_path.?,
        .last_seen_path = last_seen_path.?,
    };
}

fn parsePath(parser: *strict.Parser, allocator: std.mem.Allocator) strict.ParseError!DiagnosticPath {
    try parser.beginObject();
    var seen: u32 = 0;
    var encoding: ?PathEncoding = null;
    var encoded_value: ?[]const u8 = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "encoding")) {
            try strict.markSeen(&seen, 0);
            const value = try parser.string();
            encoding = if (std.mem.eql(u8, value, "utf8"))
                .utf8
            else if (std.mem.eql(u8, value, "base64"))
                .base64
            else
                return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "value")) {
            try strict.markSeen(&seen, 1);
            encoded_value = try parser.string();
        } else {
            return error.UnknownField;
        }
    }
    try strict.requireFields(seen, 0b11);
    const bytes = switch (encoding.?) {
        .utf8 => blk: {
            const value = encoded_value.?;
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidValue;
            try strict.validateText(value, store_path.max_store_root_bytes, false);
            break :blk value;
        },
        .base64 => blk: {
            const decoded = try decodeCanonicalBase64(allocator, encoded_value.?);
            if (isPrintableUtf8(decoded)) return error.InvalidValue;
            break :blk decoded;
        },
    };
    store_path.validateAbsoluteCanonical(bytes) catch return error.InvalidValue;
    return .{ .encoding = encoding.?, .bytes = bytes };
}

fn isPrintableUtf8(value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(value)) return false;
    strict.validateText(value, store_path.max_store_root_bytes, false) catch return false;
    return true;
}

fn decodeCanonicalBase64(allocator: std.mem.Allocator, encoded: []const u8) strict.ParseError![]const u8 {
    if (encoded.len == 0 or encoded.len > 5460 or encoded.len % 4 != 0) return error.InvalidValue;
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidValue;
    if (decoded_len == 0 or decoded_len > store_path.max_store_root_bytes) return error.LimitExceeded;
    const decoded = try allocator.alloc(u8, decoded_len);
    std.base64.standard.Decoder.decode(decoded, encoded) catch return error.InvalidValue;
    const canonical_len = std.base64.standard.Encoder.calcSize(decoded.len);
    if (canonical_len != encoded.len) return error.InvalidValue;
    const canonical = try allocator.alloc(u8, canonical_len);
    const written = std.base64.standard.Encoder.encode(canonical, decoded);
    if (!std.mem.eql(u8, written, encoded)) return error.InvalidValue;
    return decoded;
}

fn parseDecimal(value: []const u8) strict.ParseError!u64 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return error.InvalidValue;
    for (value) |byte| if (byte < '0' or byte > '9') return error.InvalidValue;
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidValue;
}

test "review history backend registry is strict sorted and locator authoritative" {
    const bytes =
        "{\"schema_version\":1,\"bindings\":[" ++
        "{\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"device\":\"7\",\"inode\":\"11\",\"canonical_path\":{\"encoding\":\"utf8\",\"value\":\"/repo/a\"},\"last_seen_path\":{\"encoding\":\"utf8\",\"value\":\"/moved/a\"}}," ++
        "{\"review_repository_id\":\"223e4567-e89b-42d3-a456-426614174000\",\"device\":\"7\",\"inode\":\"12\",\"canonical_path\":{\"encoding\":\"base64\",\"value\":\"L3JlcG8v/w==\"},\"last_seen_path\":{\"encoding\":\"utf8\",\"value\":\"/repo/b\"}}]}\n";
    var parsed = try parseStrict(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.bindings.len);
    const id = parsed.lookup(.{ .device = 7, .inode = 12 }).?;
    try std.testing.expect(id.eql(try committed_review.ReviewRepositoryId.parse("223e4567-e89b-42d3-a456-426614174000")));
    try std.testing.expectEqualSlices(u8, "/repo/\xff", parsed.bindings[1].canonical_path.bytes);
    try std.testing.expect(parsed.lookup(.{ .device = 8, .inode = 12 }) == null);
    const unsorted = [_]Binding{ parsed.bindings[1], parsed.bindings[0] };
    try std.testing.expectError(error.InvalidValue, writeCanonicalAlloc(std.testing.allocator, &unsorted));
}

test "review history backend registry rejects duplicate authority and noncanonical scalar wire" {
    const duplicate =
        "{\"schema_version\":1,\"bindings\":[" ++
        "{\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"device\":\"07\",\"inode\":\"11\",\"canonical_path\":{\"encoding\":\"utf8\",\"value\":\"/repo\"},\"last_seen_path\":{\"encoding\":\"utf8\",\"value\":\"/repo\"}}]}";
    try std.testing.expectError(error.InvalidValue, parseStrict(std.testing.allocator, duplicate));

    const unknown = "{\"schema_version\":1,\"bindings\":[],\"extra\":true}";
    try std.testing.expectError(error.UnknownField, parseStrict(std.testing.allocator, unknown));

    const noncanonical = "{ \"schema_version\":1,\"bindings\":[] }\n";
    try std.testing.expectError(error.InvalidValue, parseStrict(std.testing.allocator, noncanonical));
}

test "review history backend registry golden and negative files stay exact" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const valid = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "testdata/ai-review-store-v1/registry-valid.json",
        allocator,
        .limited(max_registry_bytes),
    );
    defer allocator.free(valid);
    var parsed = try parseStrict(allocator, valid);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.bindings.len);

    const duplicate = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "testdata/ai-review-store-v1/registry-duplicate.json",
        allocator,
        .limited(max_registry_bytes),
    );
    defer allocator.free(duplicate);
    try std.testing.expectError(error.InvalidValue, parseStrict(allocator, duplicate));
}

test "review history backend registry keeps permission and IO separate from invalid authority" {
    try std.testing.expectEqual(.permission_denied, classifyReadError(error.AccessDenied).unavailable);
    try std.testing.expectEqual(.permission_denied, classifyReadError(error.PermissionDenied).unavailable);
    try std.testing.expectEqual(.io_failed, classifyReadError(error.InputOutput).unavailable);
    try std.testing.expectEqual(.io_failed, classifyReadError(error.SystemResources).unavailable);
    try std.testing.expect(classifyReadError(error.FileNotFound) == .missing);
    for ([_]anyerror{ error.WrongType, error.WrongOwner, error.WrongMode, error.CrossDevice, error.MultipleLinks, error.SymLinkLoop, error.NotDir, error.FileSizeOutOfBounds, error.FileChangedWhileReading }) |err|
        try std.testing.expect(classifyReadError(err) == .invalid);
}
