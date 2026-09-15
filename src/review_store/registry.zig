//! Strict bounded read-only codec for the machine-local repository registry.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const strict = @import("../committed_review/strict_json.zig");
const capability = @import("capability.zig");
const store_name = @import("name.zig");
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
    repository_instance_id: committed_review.RepositoryInstanceId,
    review_repository_id: committed_review.ReviewRepositoryId,
    repository_display_name: []const u8,
    directory_name: []const u8,
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
        instance_id: committed_review.RepositoryInstanceId,
    ) ?*const Binding {
        for (self.bindings) |*binding| {
            if (binding.repository_instance_id.eql(instance_id)) return binding;
        }
        return null;
    }

    pub fn lookupPath(self: *const ParsedRegistry, path: []const u8) ?*const Binding {
        for (self.bindings) |*binding| {
            if (std.mem.eql(u8, binding.last_seen_path.bytes, path)) return binding;
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
        const instance_id = binding.repository_instance_id.canonical();
        _ = committed_review.RepositoryInstanceId.parse(&instance_id) catch return error.InvalidValue;
        const repository_id = binding.review_repository_id.canonical();
        _ = committed_review.ReviewRepositoryId.parse(&repository_id) catch return error.InvalidValue;
        const display = store_name.RepositoryDisplayName.fromStored(binding.repository_display_name) catch
            return error.InvalidValue;
        _ = store_name.RepositoryDirectoryName.fromStored(binding.directory_name, &display, binding.review_repository_id) catch
            return error.InvalidValue;
        for (bindings[0..index]) |prior| {
            if (prior.review_repository_id.eql(binding.review_repository_id) or
                std.mem.eql(u8, prior.directory_name, binding.directory_name) or
                std.mem.eql(u8, prior.last_seen_path.bytes, binding.last_seen_path.bytes)) return error.InvalidValue;
        }
        if (index != 0) {
            if (std.mem.order(u8, &bindings[index - 1].repository_instance_id.bytes, &binding.repository_instance_id.bytes) != .lt)
                return error.InvalidValue;
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
        const instance_id = binding.repository_instance_id.canonical();
        try jsonField(&stringify, "repository_instance_id", &instance_id);
        const repository_id = binding.review_repository_id.canonical();
        try jsonField(&stringify, "review_repository_id", &repository_id);
        try jsonField(&stringify, "repository_display_name", binding.repository_display_name);
        try jsonField(&stringify, "directory_name", binding.directory_name);
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
            if (prior.repository_instance_id.eql(value.repository_instance_id) or
                prior.review_repository_id.eql(value.review_repository_id) or
                std.mem.eql(u8, prior.directory_name, value.directory_name) or
                std.mem.eql(u8, prior.last_seen_path.bytes, value.last_seen_path.bytes)) return error.InvalidValue;
        }
        if (values.items.len != 0) {
            if (std.mem.order(u8, &values.items[values.items.len - 1].repository_instance_id.bytes, &value.repository_instance_id.bytes) != .lt)
                return error.InvalidValue;
        }
        try values.append(allocator, value);
    }
    return try values.toOwnedSlice(allocator);
}

fn parseBindingBody(parser: *strict.Parser, allocator: std.mem.Allocator) strict.ParseError!Binding {
    var seen: u32 = 0;
    var instance_id: ?committed_review.RepositoryInstanceId = null;
    var repository_id: ?committed_review.ReviewRepositoryId = null;
    var repository_display_name: ?[]const u8 = null;
    var directory_name: ?[]const u8 = null;
    var last_seen_path: ?DiagnosticPath = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "repository_instance_id")) {
            try strict.markSeen(&seen, 0);
            instance_id = committed_review.RepositoryInstanceId.parse(try parser.string()) catch
                return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "review_repository_id")) {
            try strict.markSeen(&seen, 1);
            repository_id = committed_review.ReviewRepositoryId.parse(try parser.string()) catch
                return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "repository_display_name")) {
            try strict.markSeen(&seen, 2);
            repository_display_name = try parser.string();
        } else if (std.mem.eql(u8, key, "directory_name")) {
            try strict.markSeen(&seen, 3);
            directory_name = try parser.string();
        } else if (std.mem.eql(u8, key, "last_seen_path")) {
            try strict.markSeen(&seen, 4);
            last_seen_path = try parsePath(parser, allocator);
        } else {
            return error.UnknownField;
        }
    }
    try strict.requireFields(seen, 0b1_1111);
    const display = store_name.RepositoryDisplayName.fromStored(repository_display_name.?) catch
        return error.InvalidValue;
    _ = store_name.RepositoryDirectoryName.fromStored(directory_name.?, &display, repository_id.?) catch
        return error.InvalidValue;
    return .{
        .repository_instance_id = instance_id.?,
        .review_repository_id = repository_id.?,
        .repository_display_name = repository_display_name.?,
        .directory_name = directory_name.?,
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

test "review store registry is strict sorted and repository instance authoritative" {
    const bytes =
        "{\"schema_version\":1,\"bindings\":[" ++
        "{\"repository_instance_id\":\"123e4567-e89b-42d3-a456-426614174010\",\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"repository_display_name\":\"Repo-A\",\"directory_name\":\"Repo-A-123e4567\",\"last_seen_path\":{\"encoding\":\"utf8\",\"value\":\"/repo/a\"}}," ++
        "{\"repository_instance_id\":\"223e4567-e89b-42d3-a456-426614174010\",\"review_repository_id\":\"223e4567-e89b-42d3-a456-426614174000\",\"repository_display_name\":\"Repo-B\",\"directory_name\":\"Repo-B-223e4567\",\"last_seen_path\":{\"encoding\":\"base64\",\"value\":\"L3JlcG8v/w==\"}}]}\n";
    var parsed = try parseStrict(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.bindings.len);
    const binding = parsed.lookup(try committed_review.RepositoryInstanceId.parse("223e4567-e89b-42d3-a456-426614174010")).?;
    try std.testing.expect(binding.review_repository_id.eql(try committed_review.ReviewRepositoryId.parse("223e4567-e89b-42d3-a456-426614174000")));
    try std.testing.expectEqualStrings("Repo-B-223e4567", binding.directory_name);
    try std.testing.expectEqualSlices(u8, "/repo/\xff", parsed.bindings[1].last_seen_path.bytes);
    try std.testing.expect(parsed.lookup(try committed_review.RepositoryInstanceId.parse("323e4567-e89b-42d3-a456-426614174010")) == null);
    try std.testing.expect(parsed.lookupPath("/repo/a") != null);
    const unsorted = [_]Binding{ parsed.bindings[1], parsed.bindings[0] };
    try std.testing.expectError(error.InvalidValue, writeCanonicalAlloc(std.testing.allocator, &unsorted));
}

test "review store registry rejects duplicate authority and noncanonical wire" {
    const mismatched_directory =
        "{\"schema_version\":1,\"bindings\":[" ++
        "{\"repository_instance_id\":\"123e4567-e89b-42d3-a456-426614174010\",\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"repository_display_name\":\"repo\",\"directory_name\":\"repo-deadbeef\",\"last_seen_path\":{\"encoding\":\"utf8\",\"value\":\"/repo\"}}]}";
    try std.testing.expectError(error.InvalidValue, parseStrict(std.testing.allocator, mismatched_directory));

    const duplicate_directory =
        "{\"schema_version\":1,\"bindings\":[" ++
        "{\"repository_instance_id\":\"123e4567-e89b-42d3-a456-426614174010\",\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"repository_display_name\":\"repo\",\"directory_name\":\"repo-123e4567\",\"last_seen_path\":{\"encoding\":\"utf8\",\"value\":\"/repo/a\"}}," ++
        "{\"repository_instance_id\":\"223e4567-e89b-42d3-a456-426614174010\",\"review_repository_id\":\"123e4567-e89b-42d3-b456-426614174001\",\"repository_display_name\":\"repo\",\"directory_name\":\"repo-123e4567\",\"last_seen_path\":{\"encoding\":\"utf8\",\"value\":\"/repo/b\"}}]}\n";
    try std.testing.expectError(error.InvalidValue, parseStrict(std.testing.allocator, duplicate_directory));

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
