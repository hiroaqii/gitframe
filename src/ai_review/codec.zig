//! Strict complete-input parsers and canonical writers for AI review v1.

const std = @import("std");
const anchor = @import("../committed_review/anchor.zig");
const artifact = @import("../committed_review/artifact.zig");
const identity = @import("../committed_review/identity.zig");
const target_mod = @import("../committed_review/target.zig");
const limits = @import("limits.zig");
const protocol = @import("protocol.zig");

pub const ParseError = error{
    ArtifactTooLarge,
    InvalidJson,
    UnsupportedSchemaVersion,
    UnknownField,
    DuplicateField,
    MissingField,
    InvalidType,
    InvalidValue,
    LimitExceeded,
} || std.mem.Allocator.Error;

pub fn Parsed(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

const max_json_depth: usize = 8;
const max_json_token_bytes: usize = 87_382;

const Parser = struct {
    scanner: std.json.Scanner,
    allocator: std.mem.Allocator,
    depth: usize = 0,

    fn init(allocator: std.mem.Allocator, bytes: []const u8) Parser {
        return .{ .scanner = std.json.Scanner.initCompleteInput(allocator, bytes), .allocator = allocator };
    }

    fn deinit(self: *Parser) void {
        self.scanner.deinit();
        self.* = undefined;
    }

    fn beginObject(self: *Parser) ParseError!void {
        if ((try self.next()) != .object_begin) return error.InvalidType;
    }

    fn beginArray(self: *Parser) ParseError!void {
        if ((try self.next()) != .array_begin) return error.InvalidType;
    }

    fn nextObjectKey(self: *Parser) ParseError!?[]const u8 {
        return switch (try self.next()) {
            .allocated_string => |value| value,
            .object_end => null,
            else => error.InvalidType,
        };
    }

    fn nextArrayObject(self: *Parser) ParseError!bool {
        return switch (try self.next()) {
            .object_begin => true,
            .array_end => false,
            else => error.InvalidType,
        };
    }

    fn string(self: *Parser) ParseError![]const u8 {
        return switch (try self.next()) {
            .allocated_string => |value| value,
            else => error.InvalidType,
        };
    }

    fn stringOrArrayEnd(self: *Parser) ParseError!?[]const u8 {
        return switch (try self.next()) {
            .allocated_string => |value| value,
            .array_end => null,
            else => error.InvalidType,
        };
    }

    fn unsigned(self: *Parser, comptime T: type) ParseError!T {
        const token = try self.next();
        const bytes = switch (token) {
            .allocated_number => |value| value,
            else => return error.InvalidType,
        };
        return parseUnsigned(T, bytes);
    }

    fn unsignedOrArrayEnd(self: *Parser, comptime T: type) ParseError!?T {
        return switch (try self.next()) {
            .allocated_number => |value| try parseUnsigned(T, value),
            .array_end => null,
            else => error.InvalidType,
        };
    }

    fn endDocument(self: *Parser) ParseError!void {
        if ((try self.next()) != .end_of_document or self.depth != 0) return error.InvalidJson;
    }

    fn next(self: *Parser) ParseError!std.json.Token {
        const token = self.scanner.nextAllocMax(
            self.allocator,
            .alloc_always,
            max_json_token_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTooLong => return error.LimitExceeded,
            error.SyntaxError, error.UnexpectedEndOfInput => return error.InvalidJson,
        };
        switch (token) {
            .object_begin, .array_begin => {
                self.depth += 1;
                if (self.depth > max_json_depth) return error.LimitExceeded;
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

fn parseUnsigned(comptime T: type, bytes: []const u8) ParseError!T {
    if (bytes.len == 0 or (bytes.len > 1 and bytes[0] == '0')) return error.InvalidValue;
    for (bytes) |byte| if (byte < '0' or byte > '9') return error.InvalidValue;
    return std.fmt.parseInt(T, bytes, 10) catch error.InvalidValue;
}

fn markSeen(seen: *u32, bit: u5) ParseError!void {
    const mask = @as(u32, 1) << bit;
    if ((seen.* & mask) != 0) return error.DuplicateField;
    seen.* |= mask;
}

fn requireFields(seen: u32, required: u32) ParseError!void {
    if ((seen & required) != required) return error.MissingField;
}

fn parseDocument(
    comptime T: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    maximum: usize,
    comptime parseValue: fn (*Parser) ParseError!T,
) ParseError!Parsed(T) {
    if (bytes.len == 0 or bytes.len > maximum) return error.ArtifactTooLarge;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parser = Parser.init(arena.allocator(), bytes);
    defer parser.deinit();
    const value = try parseValue(&parser);
    try parser.endDocument();
    return .{ .arena = arena, .value = value };
}

pub fn parsePlanSummary(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Parsed(protocol.ReviewPlanSummary) {
    var parsed = try parseDocument(protocol.ReviewPlanSummary, allocator, bytes, limits.max_plan_summary_bytes, parsePlanSummaryValue);
    errdefer parsed.deinit();
    try requireCanonicalBytes(allocator, bytes, &parsed.value, writePlanSummaryAlloc);
    return parsed;
}

pub fn parseReviewUnit(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Parsed(protocol.ReviewUnit) {
    var parsed = try parseDocument(protocol.ReviewUnit, allocator, bytes, limits.max_unit_bytes, parseReviewUnitValue);
    errdefer parsed.deinit();
    try requireCanonicalBytes(allocator, bytes, &parsed.value, writeReviewUnitAlloc);
    return parsed;
}

pub fn parseCandidatePayload(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Parsed(protocol.FindingCandidatePayload) {
    var parsed = try parseDocument(protocol.FindingCandidatePayload, allocator, bytes, limits.max_candidate_batch_bytes, parseCandidatePayloadValue);
    errdefer parsed.deinit();
    try requireCanonicalBytes(allocator, bytes, &parsed.value, writeCandidatePayloadAlloc);
    return parsed;
}

pub fn parseCandidateBatch(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Parsed(protocol.FindingCandidateBatch) {
    var parsed = try parseDocument(protocol.FindingCandidateBatch, allocator, bytes, limits.max_candidate_batch_bytes, parseCandidateBatchValue);
    errdefer parsed.deinit();
    try requireCanonicalBytes(allocator, bytes, &parsed.value, writeCandidateBatchAlloc);
    return parsed;
}

pub fn parseCapabilityResponse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Parsed(protocol.CapabilityResponse) {
    var parsed = try parseDocument(protocol.CapabilityResponse, allocator, bytes, limits.max_capabilities_bytes, parseCapabilityResponseValue);
    errdefer parsed.deinit();
    try requireCanonicalBytes(allocator, bytes, &parsed.value, writeCapabilityResponseAlloc);
    return parsed;
}

fn requireCanonicalBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    value: anytype,
    comptime writeAlloc: anytype,
) ParseError!void {
    const canonical = try writeAlloc(allocator, value);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) return error.InvalidJson;
}

fn parsePlanSummaryValue(parser: *Parser) ParseError!protocol.ReviewPlanSummary {
    try parser.beginObject();
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var target: ?target_mod.CommittedReviewTarget = null;
    var projection_digest: ?identity.Sha256Digest = null;
    var instruction_set_digest: ?identity.Sha256Digest = null;
    var unit_count: ?u16 = null;
    var plan_digest: ?identity.Sha256Digest = null;
    var limit_set: ?protocol.ReviewLimitSet = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            try markSeen(&seen, 0);
            schema_version = try parser.unsigned(u64);
        } else if (std.mem.eql(u8, key, "target")) {
            try markSeen(&seen, 1);
            target = try parseTarget(parser);
        } else if (std.mem.eql(u8, key, "projection_digest")) {
            try markSeen(&seen, 2);
            projection_digest = try parseDigest(parser);
        } else if (std.mem.eql(u8, key, "instruction_set_digest")) {
            try markSeen(&seen, 3);
            instruction_set_digest = try parseDigest(parser);
        } else if (std.mem.eql(u8, key, "unit_count")) {
            try markSeen(&seen, 4);
            unit_count = try parser.unsigned(u16);
        } else if (std.mem.eql(u8, key, "plan_digest")) {
            try markSeen(&seen, 5);
            plan_digest = try parseDigest(parser);
        } else if (std.mem.eql(u8, key, "limits")) {
            try markSeen(&seen, 6);
            limit_set = try parseLimitSet(parser);
        } else return error.UnknownField;
    }
    try requireFields(seen, 0b111_1111);
    const value: protocol.ReviewPlanSummary = .{
        .schema_version = schema_version.?,
        .target = target.?,
        .projection_digest = projection_digest.?,
        .instruction_set_digest = instruction_set_digest.?,
        .unit_count = unit_count.?,
        .plan_digest = plan_digest.?,
        .limits = limit_set.?,
    };
    try validatePlanSummary(&value);
    return value;
}

fn parseLimitSet(parser: *Parser) ParseError!protocol.ReviewLimitSet {
    try parser.beginArray();
    var index: usize = 0;
    while (try parser.nextArrayObject()) {
        if (index == limits.review_plan_limits.len) return error.LimitExceeded;
        var seen: u32 = 0;
        var name: ?[]const u8 = null;
        var value: ?u64 = null;
        while (try parser.nextObjectKey()) |key| {
            if (std.mem.eql(u8, key, "name")) {
                try markSeen(&seen, 0);
                name = try parser.string();
            } else if (std.mem.eql(u8, key, "value")) {
                try markSeen(&seen, 1);
                value = try parser.unsigned(u64);
            } else return error.UnknownField;
        }
        try requireFields(seen, 0b11);
        const expected = limits.review_plan_limits[index];
        if (!std.mem.eql(u8, name.?, expected.name) or value.? != expected.value) return error.InvalidValue;
        index += 1;
    }
    if (index != limits.review_plan_limits.len) return error.MissingField;
    return .v1;
}

fn parseCapabilityResponseValue(parser: *Parser) ParseError!protocol.CapabilityResponse {
    try parser.beginObject();
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var status_ok = false;
    var gitframe_version: ?[]const u8 = null;
    var capabilities: ?[]const protocol.Capability = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            try markSeen(&seen, 0);
            schema_version = try parser.unsigned(u64);
        } else if (std.mem.eql(u8, key, "status")) {
            try markSeen(&seen, 1);
            if (!std.mem.eql(u8, try parser.string(), "ok")) return error.InvalidValue;
            status_ok = true;
        } else if (std.mem.eql(u8, key, "gitframe_version")) {
            try markSeen(&seen, 2);
            const value = try parser.string();
            try validateText(value, 256, false, false);
            gitframe_version = value;
        } else if (std.mem.eql(u8, key, "capabilities")) {
            try markSeen(&seen, 3);
            capabilities = try parseCapabilities(parser);
        } else return error.UnknownField;
    }
    try requireFields(seen, 0b1111);
    std.debug.assert(status_ok);
    const value: protocol.CapabilityResponse = .{
        .schema_version = schema_version.?,
        .status = .ok,
        .gitframe_version = gitframe_version.?,
        .capabilities = capabilities.?,
    };
    try validateCapabilityResponse(&value);
    return value;
}

fn parseCapabilities(parser: *Parser) ParseError![]const protocol.Capability {
    try parser.beginArray();
    var list = std.array_list.Managed(protocol.Capability).init(parser.allocator);
    while (try parser.nextArrayObject()) {
        if (list.items.len == limits.max_capabilities) return error.LimitExceeded;
        var seen: u32 = 0;
        var name: ?[]const u8 = null;
        var versions: ?[]const u16 = null;
        while (try parser.nextObjectKey()) |key| {
            if (std.mem.eql(u8, key, "name")) {
                try markSeen(&seen, 0);
                name = try parser.string();
            } else if (std.mem.eql(u8, key, "versions")) {
                try markSeen(&seen, 1);
                versions = try parseVersions(parser);
            } else return error.UnknownField;
        }
        try requireFields(seen, 0b11);
        try list.append(.{ .name = name.?, .versions = versions.? });
    }
    return try list.toOwnedSlice();
}

fn parseVersions(parser: *Parser) ParseError![]const u16 {
    try parser.beginArray();
    var list = std.array_list.Managed(u16).init(parser.allocator);
    while (try parser.unsignedOrArrayEnd(u16)) |version| {
        if (list.items.len == limits.max_capability_versions) return error.LimitExceeded;
        try list.append(version);
    }
    return try list.toOwnedSlice();
}

fn parseCandidatePayloadValue(parser: *Parser) ParseError!protocol.FindingCandidatePayload {
    try parser.beginObject();
    var seen: u32 = 0;
    var findings: ?[]const protocol.FindingCandidate = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "findings")) {
            try markSeen(&seen, 0);
            findings = try parseFindings(parser);
        } else return error.UnknownField;
    }
    try requireFields(seen, 1);
    const value: protocol.FindingCandidatePayload = .{ .findings = findings.? };
    try validateCandidatePayload(&value);
    return value;
}

fn parseCandidateBatchValue(parser: *Parser) ParseError!protocol.FindingCandidateBatch {
    try parser.beginObject();
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var plan_digest: ?identity.Sha256Digest = null;
    var unit_id: ?protocol.UnitId = null;
    var status_reviewed = false;
    var findings: ?[]const protocol.FindingCandidate = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            try markSeen(&seen, 0);
            schema_version = try parser.unsigned(u64);
        } else if (std.mem.eql(u8, key, "plan_digest")) {
            try markSeen(&seen, 1);
            plan_digest = try parseDigest(parser);
        } else if (std.mem.eql(u8, key, "unit_id")) {
            try markSeen(&seen, 2);
            unit_id = protocol.UnitId.parse(try parser.string()) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "status")) {
            try markSeen(&seen, 3);
            if (!std.mem.eql(u8, try parser.string(), "reviewed")) return error.InvalidValue;
            status_reviewed = true;
        } else if (std.mem.eql(u8, key, "findings")) {
            try markSeen(&seen, 4);
            findings = try parseFindings(parser);
        } else return error.UnknownField;
    }
    try requireFields(seen, 0b1_1111);
    std.debug.assert(status_reviewed);
    const value: protocol.FindingCandidateBatch = .{
        .schema_version = schema_version.?,
        .plan_digest = plan_digest.?,
        .unit_id = unit_id.?,
        .status = .reviewed,
        .findings = findings.?,
    };
    try validateCandidateBatch(&value);
    return value;
}

fn parseFindings(parser: *Parser) ParseError![]const protocol.FindingCandidate {
    try parser.beginArray();
    var list = std.array_list.Managed(protocol.FindingCandidate).init(parser.allocator);
    while (try parser.nextArrayObject()) {
        if (list.items.len == limits.max_findings_per_unit) return error.LimitExceeded;
        var seen: u32 = 0;
        var start: ?protocol.LocationId = null;
        var end: ?protocol.LocationId = null;
        var severity: ?artifact.Severity = null;
        var title: ?[]const u8 = null;
        var body: ?[]const u8 = null;
        var suggestion: ?[]const u8 = null;
        while (try parser.nextObjectKey()) |key| {
            if (std.mem.eql(u8, key, "start_location")) {
                try markSeen(&seen, 0);
                start = protocol.LocationId.parse(try parser.string()) catch return error.InvalidValue;
            } else if (std.mem.eql(u8, key, "end_location")) {
                try markSeen(&seen, 1);
                end = protocol.LocationId.parse(try parser.string()) catch return error.InvalidValue;
            } else if (std.mem.eql(u8, key, "severity")) {
                try markSeen(&seen, 2);
                severity = try parseSeverity(try parser.string());
            } else if (std.mem.eql(u8, key, "title")) {
                try markSeen(&seen, 3);
                title = try parser.string();
            } else if (std.mem.eql(u8, key, "body")) {
                try markSeen(&seen, 4);
                body = try parser.string();
            } else if (std.mem.eql(u8, key, "suggestion")) {
                try markSeen(&seen, 5);
                suggestion = try parser.string();
            } else return error.UnknownField;
        }
        try requireFields(seen, 0b1_1111);
        try list.append(.{
            .start_location = start.?,
            .end_location = end.?,
            .severity = severity.?,
            .title = title.?,
            .body = body.?,
            .suggestion = suggestion,
        });
    }
    return try list.toOwnedSlice();
}

fn parseReviewUnitValue(parser: *Parser) ParseError!protocol.ReviewUnit {
    try parser.beginObject();
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var plan_digest: ?identity.Sha256Digest = null;
    var unit_id: ?protocol.UnitId = null;
    var ordinal: ?u16 = null;
    var unit_count: ?u16 = null;
    var old_path: ?[]const u8 = null;
    var new_path: ?[]const u8 = null;
    var display_path: ?[]const u8 = null;
    var file_status: ?protocol.FileStatus = null;
    var metadata_lines: ?[]const []const u8 = null;
    var hunks: ?[]const protocol.ReviewHunk = null;
    var locations: ?[]const protocol.ReviewLocation = null;
    var before_guidance: ?[]const protocol.Guidance = null;
    var after_guidance: ?[]const protocol.Guidance = null;
    var coverage_spans: ?[]const protocol.CoverageSpan = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            try markSeen(&seen, 0);
            schema_version = try parser.unsigned(u64);
        } else if (std.mem.eql(u8, key, "plan_digest")) {
            try markSeen(&seen, 1);
            plan_digest = try parseDigest(parser);
        } else if (std.mem.eql(u8, key, "unit_id")) {
            try markSeen(&seen, 2);
            unit_id = protocol.UnitId.parse(try parser.string()) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "ordinal")) {
            try markSeen(&seen, 3);
            ordinal = try parser.unsigned(u16);
        } else if (std.mem.eql(u8, key, "unit_count")) {
            try markSeen(&seen, 4);
            unit_count = try parser.unsigned(u16);
        } else if (std.mem.eql(u8, key, "old_path_bytes_b64")) {
            try markSeen(&seen, 5);
            old_path = try decodeRawPath(parser.allocator, try parser.string());
        } else if (std.mem.eql(u8, key, "new_path_bytes_b64")) {
            try markSeen(&seen, 6);
            new_path = try decodeRawPath(parser.allocator, try parser.string());
        } else if (std.mem.eql(u8, key, "display_path")) {
            try markSeen(&seen, 7);
            display_path = try parser.string();
        } else if (std.mem.eql(u8, key, "file_status")) {
            try markSeen(&seen, 8);
            file_status = try parseFileStatus(try parser.string());
        } else if (std.mem.eql(u8, key, "metadata_lines")) {
            try markSeen(&seen, 9);
            metadata_lines = try parseMetadataLines(parser);
        } else if (std.mem.eql(u8, key, "hunks")) {
            try markSeen(&seen, 10);
            hunks = try parseHunks(parser);
        } else if (std.mem.eql(u8, key, "locations")) {
            try markSeen(&seen, 11);
            locations = try parseLocations(parser);
        } else if (std.mem.eql(u8, key, "before_guidance")) {
            try markSeen(&seen, 12);
            before_guidance = try parseGuidance(parser);
        } else if (std.mem.eql(u8, key, "after_guidance")) {
            try markSeen(&seen, 13);
            after_guidance = try parseGuidance(parser);
        } else if (std.mem.eql(u8, key, "coverage_spans")) {
            try markSeen(&seen, 14);
            coverage_spans = try parseCoverageSpans(parser);
        } else return error.UnknownField;
    }
    const required = (@as(u32, 1) << 0) | (@as(u32, 1) << 1) | (@as(u32, 1) << 2) |
        (@as(u32, 1) << 3) | (@as(u32, 1) << 4) | (@as(u32, 1) << 7) |
        (@as(u32, 1) << 8) | (@as(u32, 1) << 9) | (@as(u32, 1) << 10) |
        (@as(u32, 1) << 11) | (@as(u32, 1) << 12) | (@as(u32, 1) << 13) |
        (@as(u32, 1) << 14);
    try requireFields(seen, required);
    const value: protocol.ReviewUnit = .{
        .schema_version = schema_version.?,
        .plan_digest = plan_digest.?,
        .unit_id = unit_id.?,
        .ordinal = ordinal.?,
        .unit_count = unit_count.?,
        .old_path_bytes = old_path,
        .new_path_bytes = new_path,
        .display_path = display_path.?,
        .file_status = file_status.?,
        .metadata_lines = metadata_lines.?,
        .hunks = hunks.?,
        .locations = locations.?,
        .before_guidance = before_guidance.?,
        .after_guidance = after_guidance.?,
        .coverage_spans = coverage_spans.?,
    };
    try validateReviewUnit(&value);
    return value;
}

fn parseMetadataLines(parser: *Parser) ParseError![]const []const u8 {
    try parser.beginArray();
    var list = std.array_list.Managed([]const u8).init(parser.allocator);
    while (try parser.stringOrArrayEnd()) |line| {
        if (list.items.len == limits.max_metadata_lines_per_unit) return error.LimitExceeded;
        try list.append(line);
    }
    return try list.toOwnedSlice();
}

fn parseHunks(parser: *Parser) ParseError![]const protocol.ReviewHunk {
    try parser.beginArray();
    var list = std.array_list.Managed(protocol.ReviewHunk).init(parser.allocator);
    while (try parser.nextArrayObject()) {
        if (list.items.len == limits.max_hunks) return error.LimitExceeded;
        var seen: u32 = 0;
        var old_start: ?u32 = null;
        var old_count: ?u32 = null;
        var new_start: ?u32 = null;
        var new_count: ?u32 = null;
        var section: ?[]const u8 = null;
        var lines: ?[]const protocol.DiffLine = null;
        while (try parser.nextObjectKey()) |key| {
            if (std.mem.eql(u8, key, "old_start")) {
                try markSeen(&seen, 0);
                old_start = try parser.unsigned(u32);
            } else if (std.mem.eql(u8, key, "old_count")) {
                try markSeen(&seen, 1);
                old_count = try parser.unsigned(u32);
            } else if (std.mem.eql(u8, key, "new_start")) {
                try markSeen(&seen, 2);
                new_start = try parser.unsigned(u32);
            } else if (std.mem.eql(u8, key, "new_count")) {
                try markSeen(&seen, 3);
                new_count = try parser.unsigned(u32);
            } else if (std.mem.eql(u8, key, "section")) {
                try markSeen(&seen, 4);
                section = try parser.string();
            } else if (std.mem.eql(u8, key, "lines")) {
                try markSeen(&seen, 5);
                lines = try parseDiffLines(parser);
            } else return error.UnknownField;
        }
        try requireFields(seen, 0b10_1111);
        try list.append(.{
            .old_start = old_start.?,
            .old_count = old_count.?,
            .new_start = new_start.?,
            .new_count = new_count.?,
            .section = section,
            .lines = lines.?,
        });
    }
    return try list.toOwnedSlice();
}

fn parseDiffLines(parser: *Parser) ParseError![]const protocol.DiffLine {
    try parser.beginArray();
    var list = std.array_list.Managed(protocol.DiffLine).init(parser.allocator);
    while (try parser.nextArrayObject()) {
        if (list.items.len == limits.max_lines_per_unit) return error.LimitExceeded;
        var seen: u32 = 0;
        var kind: ?protocol.DiffLineKind = null;
        var text: ?[]const u8 = null;
        var line_ending: ?protocol.LineEnding = null;
        var before_location: ?protocol.LocationId = null;
        var after_location: ?protocol.LocationId = null;
        while (try parser.nextObjectKey()) |key| {
            if (std.mem.eql(u8, key, "kind")) {
                try markSeen(&seen, 0);
                kind = try parseDiffLineKind(try parser.string());
            } else if (std.mem.eql(u8, key, "text")) {
                try markSeen(&seen, 1);
                text = try parser.string();
            } else if (std.mem.eql(u8, key, "line_ending")) {
                try markSeen(&seen, 2);
                line_ending = try parseLineEnding(try parser.string());
            } else if (std.mem.eql(u8, key, "before_location")) {
                try markSeen(&seen, 3);
                before_location = protocol.LocationId.parse(try parser.string()) catch return error.InvalidValue;
            } else if (std.mem.eql(u8, key, "after_location")) {
                try markSeen(&seen, 4);
                after_location = protocol.LocationId.parse(try parser.string()) catch return error.InvalidValue;
            } else return error.UnknownField;
        }
        try requireFields(seen, 0b111);
        try list.append(.{
            .kind = kind.?,
            .text = text.?,
            .line_ending = line_ending.?,
            .before_location = before_location,
            .after_location = after_location,
        });
    }
    return try list.toOwnedSlice();
}

fn parseLocations(parser: *Parser) ParseError![]const protocol.ReviewLocation {
    try parser.beginArray();
    var list = std.array_list.Managed(protocol.ReviewLocation).init(parser.allocator);
    while (try parser.nextArrayObject()) {
        if (list.items.len == limits.max_lines_per_unit) return error.LimitExceeded;
        var seen: u32 = 0;
        var location_id: ?protocol.LocationId = null;
        var path_bytes: ?[]const u8 = null;
        var side: ?anchor.AnchorSide = null;
        var line: ?u32 = null;
        while (try parser.nextObjectKey()) |key| {
            if (std.mem.eql(u8, key, "location_id")) {
                try markSeen(&seen, 0);
                location_id = protocol.LocationId.parse(try parser.string()) catch return error.InvalidValue;
            } else if (std.mem.eql(u8, key, "path_bytes_b64")) {
                try markSeen(&seen, 1);
                path_bytes = try decodeRawPath(parser.allocator, try parser.string());
            } else if (std.mem.eql(u8, key, "side")) {
                try markSeen(&seen, 2);
                side = try parseSide(try parser.string());
            } else if (std.mem.eql(u8, key, "line")) {
                try markSeen(&seen, 3);
                line = try parser.unsigned(u32);
            } else return error.UnknownField;
        }
        try requireFields(seen, 0b1111);
        try list.append(.{
            .location_id = location_id.?,
            .path_bytes = path_bytes.?,
            .side = side.?,
            .line = line.?,
        });
    }
    return try list.toOwnedSlice();
}

fn parseGuidance(parser: *Parser) ParseError![]const protocol.Guidance {
    try parser.beginArray();
    var list = std.array_list.Managed(protocol.Guidance).init(parser.allocator);
    while (try parser.nextArrayObject()) {
        if (list.items.len == limits.max_guidance_path_depth + 1) return error.LimitExceeded;
        var seen: u32 = 0;
        var head_oid: ?[]const u8 = null;
        var path_bytes: ?[]const u8 = null;
        var blob_oid: ?[]const u8 = null;
        var content_digest: ?identity.Sha256Digest = null;
        var content: ?[]const u8 = null;
        while (try parser.nextObjectKey()) |key| {
            if (std.mem.eql(u8, key, "head_oid")) {
                try markSeen(&seen, 0);
                head_oid = try parser.string();
            } else if (std.mem.eql(u8, key, "path_bytes_b64")) {
                try markSeen(&seen, 1);
                path_bytes = try decodeRawPath(parser.allocator, try parser.string());
            } else if (std.mem.eql(u8, key, "blob_oid")) {
                try markSeen(&seen, 2);
                blob_oid = try parser.string();
            } else if (std.mem.eql(u8, key, "content_digest")) {
                try markSeen(&seen, 3);
                content_digest = try parseDigest(parser);
            } else if (std.mem.eql(u8, key, "content")) {
                try markSeen(&seen, 4);
                content = try parser.string();
            } else return error.UnknownField;
        }
        try requireFields(seen, 0b1_1111);
        try list.append(.{
            .head_oid = head_oid.?,
            .path_bytes = path_bytes.?,
            .blob_oid = blob_oid.?,
            .content_digest = content_digest.?,
            .content = content.?,
        });
    }
    return try list.toOwnedSlice();
}

fn parseCoverageSpans(parser: *Parser) ParseError![]const protocol.CoverageSpan {
    try parser.beginArray();
    var list = std.array_list.Managed(protocol.CoverageSpan).init(parser.allocator);
    while (try parser.nextArrayObject()) {
        if (list.items.len == limits.max_coverage_spans_per_unit) return error.LimitExceeded;
        var seen: u32 = 0;
        var start: ?u32 = null;
        var end_exclusive: ?u32 = null;
        while (try parser.nextObjectKey()) |key| {
            if (std.mem.eql(u8, key, "start")) {
                try markSeen(&seen, 0);
                start = try parser.unsigned(u32);
            } else if (std.mem.eql(u8, key, "end_exclusive")) {
                try markSeen(&seen, 1);
                end_exclusive = try parser.unsigned(u32);
            } else return error.UnknownField;
        }
        try requireFields(seen, 0b11);
        try list.append(.{ .start = start.?, .end_exclusive = end_exclusive.? });
    }
    return try list.toOwnedSlice();
}

fn parseTarget(parser: *Parser) ParseError!target_mod.CommittedReviewTarget {
    try parser.beginObject();
    var seen: u32 = 0;
    var object_format: ?target_mod.ObjectFormat = null;
    var source_kind: ?target_mod.SourceKind = null;
    var base_oid: ?[]const u8 = null;
    var head_oid: ?[]const u8 = null;
    var diff_base_oid: ?[]const u8 = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "object_format")) {
            try markSeen(&seen, 0);
            object_format = try parseObjectFormat(try parser.string());
        } else if (std.mem.eql(u8, key, "source_kind")) {
            try markSeen(&seen, 1);
            if (!std.mem.eql(u8, try parser.string(), "branch_range")) return error.InvalidValue;
            source_kind = .branch_range;
        } else if (std.mem.eql(u8, key, "base_oid")) {
            try markSeen(&seen, 2);
            base_oid = try parser.string();
        } else if (std.mem.eql(u8, key, "head_oid")) {
            try markSeen(&seen, 3);
            head_oid = try parser.string();
        } else if (std.mem.eql(u8, key, "diff_base_oid")) {
            try markSeen(&seen, 4);
            diff_base_oid = try parser.string();
        } else return error.UnknownField;
    }
    try requireFields(seen, 0b1_1111);
    const format = object_format.?;
    return .{
        .object_format = format,
        .source_kind = source_kind.?,
        .base_oid = target_mod.ObjectId.parse(format, base_oid.?) catch return error.InvalidValue,
        .head_oid = target_mod.ObjectId.parse(format, head_oid.?) catch return error.InvalidValue,
        .diff_base_oid = target_mod.ObjectId.parse(format, diff_base_oid.?) catch return error.InvalidValue,
    };
}

fn parseDigest(parser: *Parser) ParseError!identity.Sha256Digest {
    return identity.Sha256Digest.parse(try parser.string()) catch error.InvalidValue;
}

fn validatePlanSummary(value: *const protocol.ReviewPlanSummary) ParseError!void {
    try validateSchema(value.schema_version);
    value.target.validate() catch return error.InvalidValue;
    if (value.unit_count > limits.max_review_units) return error.LimitExceeded;
    if (value.limits != .v1) return error.InvalidValue;
}

fn validateCapabilityResponse(value: *const protocol.CapabilityResponse) ParseError!void {
    try validateSchema(value.schema_version);
    try validateText(value.gitframe_version, limits.max_gitframe_version_bytes, false, false);
    if (value.capabilities.len > limits.max_capabilities) return error.LimitExceeded;
    for (value.capabilities, 0..) |capability, index| {
        try validateText(capability.name, limits.max_capability_name_bytes, false, false);
        if (index > 0 and std.mem.order(u8, value.capabilities[index - 1].name, capability.name) != .lt) {
            return error.InvalidValue;
        }
        if (capability.versions.len == 0) return error.MissingField;
        if (capability.versions.len > limits.max_capability_versions) return error.LimitExceeded;
        for (capability.versions, 0..) |version, version_index| {
            if (version == 0) return error.InvalidValue;
            if (version_index > 0 and capability.versions[version_index - 1] >= version) return error.InvalidValue;
        }
    }
}

fn validateCandidatePayload(value: *const protocol.FindingCandidatePayload) ParseError!void {
    if (value.findings.len > limits.max_findings_per_unit) return error.LimitExceeded;
    for (value.findings) |finding| try validateCandidate(finding);
}

fn validateCandidateBatch(value: *const protocol.FindingCandidateBatch) ParseError!void {
    try validateSchema(value.schema_version);
    try validateUnitId(value.unit_id);
    if (value.status != .reviewed) return error.InvalidValue;
    try validateCandidatePayload(&.{ .findings = value.findings });
}

fn validateCandidate(value: protocol.FindingCandidate) ParseError!void {
    try validateLocationId(value.start_location);
    try validateLocationId(value.end_location);
    if (value.start_location.side != value.end_location.side or
        value.start_location.ordinal > value.end_location.ordinal)
    {
        return error.InvalidValue;
    }
    try validateText(value.title, limits.max_title_bytes, false, false);
    try validateText(value.body, limits.max_body_bytes, true, false);
    if (value.suggestion) |suggestion| {
        try validateText(suggestion, limits.max_suggestion_bytes, true, false);
    }
}

fn validateUnitId(value: protocol.UnitId) ParseError!void {
    if (value.ordinal == 0 or value.ordinal > limits.max_review_units) return error.InvalidValue;
}

fn validateLocationId(value: protocol.LocationId) ParseError!void {
    if (value.ordinal == 0 or value.ordinal > limits.max_locations_per_side) return error.InvalidValue;
}

const SourcePosition = struct {
    line: u64,
    after_line: bool,
};

const SourceSpan = struct {
    first: SourcePosition,
    last: SourcePosition,
};

/// Unified-diff zero-count ranges identify the boundary after `start` (with
/// zero meaning the boundary before line one). Non-empty ranges identify the
/// committed lines themselves. This gives both forms one strict source order.
fn sourceSpan(start: u32, count: u32) SourceSpan {
    if (count == 0) {
        const position: SourcePosition = .{ .line = start, .after_line = true };
        return .{ .first = position, .last = position };
    }
    return .{
        .first = .{ .line = start, .after_line = false },
        .last = .{ .line = @as(u64, start) + count - 1, .after_line = false },
    };
}

fn sourcePositionBefore(left: SourcePosition, right: SourcePosition) bool {
    if (left.line != right.line) return left.line < right.line;
    return !left.after_line and right.after_line;
}

fn validateReviewUnit(value: *const protocol.ReviewUnit) ParseError!void {
    try validateSchema(value.schema_version);
    if (value.ordinal == 0 or value.ordinal > limits.max_review_units or
        value.unit_count == 0 or value.unit_count > limits.max_review_units or
        value.ordinal > value.unit_count or value.unit_id.ordinal != value.ordinal)
    {
        return error.InvalidValue;
    }
    if (value.old_path_bytes) |path| try validateRepositoryPath(path);
    if (value.new_path_bytes) |path| try validateRepositoryPath(path);
    try validateText(value.display_path, limits.max_display_path_bytes, false, false);
    try validateStatusPaths(value.file_status, value.old_path_bytes, value.new_path_bytes);

    if (value.metadata_lines.len > limits.max_metadata_lines_per_unit) return error.LimitExceeded;
    for (value.metadata_lines) |line| try validateDiffText(line, limits.max_metadata_line_bytes);
    if (value.hunks.len == 0) return error.MissingField;
    if (value.hunks.len > limits.max_hunks) return error.LimitExceeded;

    const before_count = try validateLocations(value);
    var next_before: u16 = 1;
    var next_after: u16 = 1;
    var total_lines: usize = 0;
    var previous_old_end: ?SourcePosition = null;
    var previous_new_end: ?SourcePosition = null;
    var old_ended_without_lf = false;
    var new_ended_without_lf = false;
    for (value.hunks) |hunk| {
        if ((hunk.old_count > 0 and hunk.old_start == 0) or
            (hunk.new_count > 0 and hunk.new_start == 0) or hunk.lines.len == 0)
        {
            return error.InvalidValue;
        }
        const old_span = sourceSpan(hunk.old_start, hunk.old_count);
        const new_span = sourceSpan(hunk.new_start, hunk.new_count);
        if (previous_old_end) |previous| {
            if (!sourcePositionBefore(previous, old_span.first)) return error.InvalidValue;
        }
        if (previous_new_end) |previous| {
            if (!sourcePositionBefore(previous, new_span.first)) return error.InvalidValue;
        }
        previous_old_end = old_span.last;
        previous_new_end = new_span.last;
        if (hunk.section) |section| try validateDiffText(section, limits.max_hunk_section_bytes);
        total_lines = std.math.add(usize, total_lines, hunk.lines.len) catch return error.LimitExceeded;
        if (total_lines > limits.max_lines_per_unit) return error.LimitExceeded;

        var old_line: u64 = hunk.old_start;
        var new_line: u64 = hunk.new_start;
        var old_used: u64 = 0;
        var new_used: u64 = 0;
        for (hunk.lines) |line| {
            try validateDiffText(line.text, limits.max_diff_line_bytes);
            const consumes_old = line.kind != .added;
            const consumes_new = line.kind != .removed;
            if ((consumes_old and old_ended_without_lf) or (consumes_new and new_ended_without_lf)) {
                return error.InvalidValue;
            }
            switch (line.kind) {
                .context => {
                    const before_id = line.before_location orelse return error.MissingField;
                    const after_id = line.after_location orelse return error.MissingField;
                    if (before_id.side != .before or before_id.ordinal != next_before or
                        after_id.side != .after or after_id.ordinal != next_after)
                    {
                        return error.InvalidValue;
                    }
                    try validateLocationReference(value, before_count, before_id, old_line);
                    try validateLocationReference(value, before_count, after_id, new_line);
                    next_before = std.math.add(u16, next_before, 1) catch return error.LimitExceeded;
                    next_after = std.math.add(u16, next_after, 1) catch return error.LimitExceeded;
                    old_line += 1;
                    new_line += 1;
                    old_used += 1;
                    new_used += 1;
                },
                .removed => {
                    const before_id = line.before_location orelse return error.MissingField;
                    if (line.after_location != null or before_id.side != .before or before_id.ordinal != next_before) {
                        return error.InvalidValue;
                    }
                    try validateLocationReference(value, before_count, before_id, old_line);
                    next_before = std.math.add(u16, next_before, 1) catch return error.LimitExceeded;
                    old_line += 1;
                    old_used += 1;
                },
                .added => {
                    const after_id = line.after_location orelse return error.MissingField;
                    if (line.before_location != null or after_id.side != .after or after_id.ordinal != next_after) {
                        return error.InvalidValue;
                    }
                    try validateLocationReference(value, before_count, after_id, new_line);
                    next_after = std.math.add(u16, next_after, 1) catch return error.LimitExceeded;
                    new_line += 1;
                    new_used += 1;
                },
            }
            if (line.line_ending == .none) {
                if (consumes_old) old_ended_without_lf = true;
                if (consumes_new) new_ended_without_lf = true;
            }
        }
        if (old_used != hunk.old_count or new_used != hunk.new_count) return error.InvalidValue;
    }
    if (@as(usize, next_before - 1) != before_count or
        @as(usize, next_after - 1) != value.locations.len - before_count)
    {
        return error.InvalidValue;
    }

    try validateGuidance(
        value.before_guidance,
        value.old_path_bytes,
        value.after_guidance,
        value.new_path_bytes,
    );
    try validateCoverage(value.coverage_spans);
}

fn validateLocations(value: *const protocol.ReviewUnit) ParseError!usize {
    if (value.locations.len == 0 or value.locations.len > limits.max_lines_per_unit) return error.LimitExceeded;
    var before_count: usize = 0;
    var saw_after = false;
    var expected_before: u16 = 1;
    var expected_after: u16 = 1;
    for (value.locations) |location| {
        if (location.line == 0 or location.location_id.side != location.side) return error.InvalidValue;
        const expected_path = switch (location.side) {
            .before => value.old_path_bytes orelse return error.InvalidValue,
            .after => value.new_path_bytes orelse return error.InvalidValue,
        };
        if (!std.mem.eql(u8, expected_path, location.path_bytes)) return error.InvalidValue;
        switch (location.side) {
            .before => {
                if (saw_after or location.location_id.ordinal != expected_before) return error.InvalidValue;
                expected_before = std.math.add(u16, expected_before, 1) catch return error.LimitExceeded;
                before_count += 1;
            },
            .after => {
                saw_after = true;
                if (location.location_id.ordinal != expected_after) return error.InvalidValue;
                expected_after = std.math.add(u16, expected_after, 1) catch return error.LimitExceeded;
            },
        }
    }
    if (before_count > limits.max_locations_per_side or
        value.locations.len - before_count > limits.max_locations_per_side)
    {
        return error.LimitExceeded;
    }
    return before_count;
}

fn validateLocationReference(
    value: *const protocol.ReviewUnit,
    before_count: usize,
    id: protocol.LocationId,
    expected_line: u64,
) ParseError!void {
    if (expected_line == 0 or expected_line > std.math.maxInt(u32)) return error.InvalidValue;
    const index = switch (id.side) {
        .before => @as(usize, id.ordinal - 1),
        .after => before_count + @as(usize, id.ordinal - 1),
    };
    if (index >= value.locations.len) return error.InvalidValue;
    const location = value.locations[index];
    if (!location.location_id.eql(id) or location.line != expected_line) return error.InvalidValue;
}

fn validateGuidance(
    before: []const protocol.Guidance,
    old_path: ?[]const u8,
    after: []const protocol.Guidance,
    new_path: ?[]const u8,
) ParseError!void {
    if (before.len > limits.max_guidance_path_depth + 1 or after.len > limits.max_guidance_path_depth + 1) {
        return error.LimitExceeded;
    }
    var total: usize = 0;
    var exact_head: ?[]const u8 = null;
    try validateGuidanceChain(before, old_path, &exact_head, &total);
    try validateGuidanceChain(after, new_path, &exact_head, &total);
    try validateGuidanceUnion(before, after);
    if (total > limits.max_guidance_per_unit_bytes) return error.LimitExceeded;
}

fn validateGuidanceUnion(
    before: []const protocol.Guidance,
    after: []const protocol.Guidance,
) ParseError!void {
    var unique_count = before.len;
    for (after) |after_item| {
        var repeated = false;
        for (before) |before_item| {
            if (!sameGuidanceSourceKey(before_item, after_item)) continue;
            repeated = true;
            if (!sameGuidanceSource(before_item, after_item)) return error.InvalidValue;
            break;
        }
        if (!repeated) {
            unique_count = std.math.add(usize, unique_count, 1) catch return error.LimitExceeded;
        }
    }
    if (unique_count > limits.max_guidance_files) return error.LimitExceeded;
}

fn sameGuidanceSourceKey(left: protocol.Guidance, right: protocol.Guidance) bool {
    return std.mem.eql(u8, left.head_oid, right.head_oid) and
        std.mem.eql(u8, left.path_bytes, right.path_bytes);
}

fn sameGuidanceSource(left: protocol.Guidance, right: protocol.Guidance) bool {
    return std.mem.eql(u8, left.blob_oid, right.blob_oid) and
        left.content_digest.eql(right.content_digest) and
        std.mem.eql(u8, left.content, right.content);
}

fn validateGuidanceChain(
    chain: []const protocol.Guidance,
    file_path: ?[]const u8,
    exact_head: *?[]const u8,
    total: *usize,
) ParseError!void {
    const path = file_path orelse {
        if (chain.len != 0) return error.InvalidValue;
        return;
    };
    if (repositoryPathParentDepth(path) > limits.max_guidance_path_depth) return error.LimitExceeded;

    var previous_directory: ?[]const u8 = null;
    for (chain) |item| {
        try validateGuidanceItem(item);
        if (exact_head.*) |head| {
            if (!std.mem.eql(u8, head, item.head_oid)) return error.InvalidValue;
        } else {
            exact_head.* = item.head_oid;
        }
        const directory = guidanceDirectory(item.path_bytes) orelse return error.InvalidValue;
        if (!isStrictPathAncestor(directory, path)) return error.InvalidValue;
        if (previous_directory) |previous| {
            if (!isStrictPathAncestor(previous, directory)) return error.InvalidValue;
        }
        previous_directory = directory;
        total.* = std.math.add(usize, total.*, item.content.len) catch return error.LimitExceeded;
    }
}

fn repositoryPathParentDepth(path: []const u8) usize {
    return std.mem.count(u8, path, "/");
}

fn validateGuidanceItem(value: protocol.Guidance) ParseError!void {
    try validateOidPair(value.head_oid, value.blob_oid);
    try validateRepositoryPath(value.path_bytes);
    if (value.content.len > limits.max_guidance_file_bytes) return error.LimitExceeded;
    try validateDocumentText(value.content);
    if (!value.content_digest.eql(identity.Sha256Digest.hash(value.content))) return error.InvalidValue;
}

fn guidanceDirectory(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "AGENTS.md")) return path[0..0];
    const suffix = "/AGENTS.md";
    if (path.len <= suffix.len or !std.mem.endsWith(u8, path, suffix)) return null;
    return path[0 .. path.len - suffix.len];
}

fn isStrictPathAncestor(parent: []const u8, child: []const u8) bool {
    if (parent.len == 0) return child.len > 0;
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}

fn validateCoverage(spans: []const protocol.CoverageSpan) ParseError!void {
    if (spans.len == 0) return error.MissingField;
    if (spans.len > limits.max_coverage_spans_per_unit) return error.LimitExceeded;
    var previous_end: u32 = 0;
    var total: usize = 0;
    for (spans, 0..) |span, index| {
        if (span.start >= span.end_exclusive or span.end_exclusive > limits.max_projection_bytes or
            (index > 0 and span.start < previous_end))
        {
            return error.InvalidValue;
        }
        total = std.math.add(usize, total, span.end_exclusive - span.start) catch return error.LimitExceeded;
        if (total > limits.max_unit_raw_fragment_bytes) return error.LimitExceeded;
        previous_end = span.end_exclusive;
    }
}

fn validateStatusPaths(status: protocol.FileStatus, old_path: ?[]const u8, new_path: ?[]const u8) ParseError!void {
    switch (status) {
        .added => if (old_path != null or new_path == null) return error.InvalidValue,
        .deleted => if (old_path == null or new_path != null) return error.InvalidValue,
        .modified => if (old_path == null or new_path == null or !std.mem.eql(u8, old_path.?, new_path.?)) return error.InvalidValue,
        .renamed, .copied => if (old_path == null or new_path == null or std.mem.eql(u8, old_path.?, new_path.?)) return error.InvalidValue,
    }
}

fn validateSchema(version: u64) ParseError!void {
    if (version != limits.schema_version) return error.UnsupportedSchemaVersion;
}

fn validateRawPath(path: []const u8) ParseError!void {
    if (path.len == 0 or path.len > limits.max_raw_path_bytes) return error.LimitExceeded;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidValue;
}

fn validateRepositoryPath(path: []const u8) ParseError!void {
    try validateRawPath(path);
    if (path[0] == '/' or path[path.len - 1] == '/') return error.InvalidValue;
    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidValue;
        }
    }
}

fn validateText(text: []const u8, maximum: usize, multiline: bool, allow_empty: bool) ParseError!void {
    if ((!allow_empty and text.len == 0) or text.len > maximum) return error.LimitExceeded;
    var iterator = (std.unicode.Utf8View.init(text) catch return error.InvalidValue).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == 0 or codepoint == 0x1b or codepoint == 0x0d or codepoint == 0x7f or
            (codepoint >= 0x80 and codepoint <= 0x9f)) return error.InvalidValue;
        if (codepoint < 0x20 and !(multiline and (codepoint == '\n' or codepoint == '\t'))) {
            return error.InvalidValue;
        }
    }
}

fn validateDiffText(text: []const u8, maximum: usize) ParseError!void {
    if (text.len > maximum) return error.LimitExceeded;
    var iterator = (std.unicode.Utf8View.init(text) catch return error.InvalidValue).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == 0 or codepoint == 0x1b or codepoint == '\n' or codepoint == '\r' or
            codepoint == 0x7f or (codepoint >= 0x80 and codepoint <= 0x9f) or
            (codepoint < 0x20 and codepoint != '\t')) return error.InvalidValue;
    }
}

fn validateDocumentText(text: []const u8) ParseError!void {
    var iterator = (std.unicode.Utf8View.init(text) catch return error.InvalidValue).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == 0 or codepoint == 0x1b or codepoint == 0x7f or
            (codepoint >= 0x80 and codepoint <= 0x9f) or
            (codepoint < 0x20 and codepoint != '\t' and codepoint != '\n' and codepoint != '\r'))
        {
            return error.InvalidValue;
        }
    }
    for (text, 0..) |byte, index| {
        if (byte == '\r' and (index + 1 == text.len or text[index + 1] != '\n')) return error.InvalidValue;
    }
}

fn validateOidPair(head_oid: []const u8, blob_oid: []const u8) ParseError!void {
    if ((head_oid.len != 40 and head_oid.len != 64) or blob_oid.len != head_oid.len) return error.InvalidValue;
    for (head_oid) |byte| if (!isLowerHex(byte)) return error.InvalidValue;
    for (blob_oid) |byte| if (!isLowerHex(byte)) return error.InvalidValue;
}

fn decodeRawPath(allocator: std.mem.Allocator, encoded: []const u8) ParseError![]const u8 {
    if (encoded.len == 0 or encoded.len > max_json_token_bytes) return error.LimitExceeded;
    for (encoded) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidValue;
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return error.InvalidValue;
    if (decoded_len == 0 or decoded_len > limits.max_raw_path_bytes) return error.LimitExceeded;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded) catch return error.InvalidValue;
    try validateRawPath(decoded);
    const canonical = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(decoded.len));
    defer allocator.free(canonical);
    const written = std.base64.url_safe_no_pad.Encoder.encode(canonical, decoded);
    if (!std.mem.eql(u8, written, encoded)) return error.InvalidValue;
    return decoded;
}

fn parseObjectFormat(text: []const u8) ParseError!target_mod.ObjectFormat {
    if (std.mem.eql(u8, text, "sha1")) return .sha1;
    if (std.mem.eql(u8, text, "sha256")) return .sha256;
    return error.InvalidValue;
}

fn parseSide(text: []const u8) ParseError!anchor.AnchorSide {
    if (std.mem.eql(u8, text, "before")) return .before;
    if (std.mem.eql(u8, text, "after")) return .after;
    return error.InvalidValue;
}

fn parseFileStatus(text: []const u8) ParseError!protocol.FileStatus {
    inline for (.{ .{ "added", protocol.FileStatus.added }, .{ "modified", protocol.FileStatus.modified }, .{ "deleted", protocol.FileStatus.deleted }, .{ "renamed", protocol.FileStatus.renamed }, .{ "copied", protocol.FileStatus.copied } }) |entry| {
        if (std.mem.eql(u8, text, entry[0])) return entry[1];
    }
    return error.InvalidValue;
}

fn parseDiffLineKind(text: []const u8) ParseError!protocol.DiffLineKind {
    if (std.mem.eql(u8, text, "context")) return .context;
    if (std.mem.eql(u8, text, "removed")) return .removed;
    if (std.mem.eql(u8, text, "added")) return .added;
    return error.InvalidValue;
}

fn parseLineEnding(text: []const u8) ParseError!protocol.LineEnding {
    if (std.mem.eql(u8, text, "lf")) return .lf;
    if (std.mem.eql(u8, text, "crlf")) return .crlf;
    if (std.mem.eql(u8, text, "none")) return .none;
    return error.InvalidValue;
}

fn parseSeverity(text: []const u8) ParseError!artifact.Severity {
    if (std.mem.eql(u8, text, "info")) return .info;
    if (std.mem.eql(u8, text, "warning")) return .warning;
    if (std.mem.eql(u8, text, "error")) return .@"error";
    return error.InvalidValue;
}

fn isLowerHex(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
}

const WriteError = std.mem.Allocator.Error || error{WriteFailed};

pub fn writePlanSummaryAlloc(allocator: std.mem.Allocator, value: *const protocol.ReviewPlanSummary) ParseError![]u8 {
    try validatePlanSummary(value);
    return writeDocumentAlloc(allocator, limits.max_plan_summary_bytes, value, writePlanSummary);
}

pub fn writeReviewUnitAlloc(allocator: std.mem.Allocator, value: *const protocol.ReviewUnit) ParseError![]u8 {
    try validateReviewUnit(value);
    return writeDocumentAlloc(allocator, limits.max_unit_bytes, value, writeReviewUnit);
}

pub fn writeCandidatePayloadAlloc(allocator: std.mem.Allocator, value: *const protocol.FindingCandidatePayload) ParseError![]u8 {
    try validateCandidatePayload(value);
    return writeDocumentAlloc(allocator, limits.max_candidate_batch_bytes, value, writeCandidatePayload);
}

pub fn writeCandidateBatchAlloc(allocator: std.mem.Allocator, value: *const protocol.FindingCandidateBatch) ParseError![]u8 {
    try validateCandidateBatch(value);
    return writeDocumentAlloc(allocator, limits.max_candidate_batch_bytes, value, writeCandidateBatch);
}

pub fn writeCapabilityResponseAlloc(allocator: std.mem.Allocator, value: *const protocol.CapabilityResponse) ParseError![]u8 {
    try validateCapabilityResponse(value);
    return writeDocumentAlloc(allocator, limits.max_capabilities_bytes, value, writeCapabilityResponse);
}

fn writeDocumentAlloc(
    allocator: std.mem.Allocator,
    maximum: usize,
    value: anytype,
    comptime writeValue: anytype,
) ParseError![]u8 {
    const storage = try allocator.alloc(u8, maximum);
    errdefer allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    writeValue(&stringify, allocator, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ArtifactTooLarge,
    };
    writer.writeByte('\n') catch return error.ArtifactTooLarge;
    return try allocator.realloc(storage, writer.buffered().len);
}

fn writePlanSummary(
    stringify: *std.json.Stringify,
    _: std.mem.Allocator,
    value: *const protocol.ReviewPlanSummary,
) WriteError!void {
    try stringify.beginObject();
    try fieldUnsigned(stringify, "schema_version", value.schema_version);
    try stringify.objectField("target");
    try writeTarget(stringify, &value.target);
    try fieldDigest(stringify, "projection_digest", value.projection_digest);
    try fieldDigest(stringify, "instruction_set_digest", value.instruction_set_digest);
    try fieldUnsigned(stringify, "unit_count", value.unit_count);
    try fieldDigest(stringify, "plan_digest", value.plan_digest);
    try stringify.objectField("limits");
    try stringify.beginArray();
    for (limits.review_plan_limits) |entry| {
        try stringify.beginObject();
        try fieldString(stringify, "name", entry.name);
        try fieldUnsigned(stringify, "value", entry.value);
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.endObject();
}

fn writeCapabilityResponse(
    stringify: *std.json.Stringify,
    _: std.mem.Allocator,
    value: *const protocol.CapabilityResponse,
) WriteError!void {
    try stringify.beginObject();
    try fieldUnsigned(stringify, "schema_version", value.schema_version);
    try fieldString(stringify, "status", "ok");
    try fieldString(stringify, "gitframe_version", value.gitframe_version);
    try stringify.objectField("capabilities");
    try stringify.beginArray();
    for (value.capabilities) |capability| {
        try stringify.beginObject();
        try fieldString(stringify, "name", capability.name);
        try stringify.objectField("versions");
        try stringify.beginArray();
        for (capability.versions) |version| try stringify.write(version);
        try stringify.endArray();
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.endObject();
}

fn writeCandidatePayload(
    stringify: *std.json.Stringify,
    _: std.mem.Allocator,
    value: *const protocol.FindingCandidatePayload,
) WriteError!void {
    try stringify.beginObject();
    try stringify.objectField("findings");
    try writeFindings(stringify, value.findings);
    try stringify.endObject();
}

fn writeCandidateBatch(
    stringify: *std.json.Stringify,
    _: std.mem.Allocator,
    value: *const protocol.FindingCandidateBatch,
) WriteError!void {
    try stringify.beginObject();
    try fieldUnsigned(stringify, "schema_version", value.schema_version);
    try fieldDigest(stringify, "plan_digest", value.plan_digest);
    try fieldUnitId(stringify, "unit_id", value.unit_id);
    try fieldString(stringify, "status", "reviewed");
    try stringify.objectField("findings");
    try writeFindings(stringify, value.findings);
    try stringify.endObject();
}

fn writeFindings(stringify: *std.json.Stringify, findings: []const protocol.FindingCandidate) WriteError!void {
    try stringify.beginArray();
    for (findings) |finding| {
        try stringify.beginObject();
        try fieldLocationId(stringify, "start_location", finding.start_location);
        try fieldLocationId(stringify, "end_location", finding.end_location);
        try fieldString(stringify, "severity", severityName(finding.severity));
        try fieldString(stringify, "title", finding.title);
        try fieldString(stringify, "body", finding.body);
        if (finding.suggestion) |suggestion| try fieldString(stringify, "suggestion", suggestion);
        try stringify.endObject();
    }
    try stringify.endArray();
}

fn writeReviewUnit(
    stringify: *std.json.Stringify,
    allocator: std.mem.Allocator,
    value: *const protocol.ReviewUnit,
) WriteError!void {
    try stringify.beginObject();
    try fieldUnsigned(stringify, "schema_version", value.schema_version);
    try fieldDigest(stringify, "plan_digest", value.plan_digest);
    try fieldUnitId(stringify, "unit_id", value.unit_id);
    try fieldUnsigned(stringify, "ordinal", value.ordinal);
    try fieldUnsigned(stringify, "unit_count", value.unit_count);
    if (value.old_path_bytes) |path| try fieldRawPath(stringify, allocator, "old_path_bytes_b64", path);
    if (value.new_path_bytes) |path| try fieldRawPath(stringify, allocator, "new_path_bytes_b64", path);
    try fieldString(stringify, "display_path", value.display_path);
    try fieldString(stringify, "file_status", fileStatusName(value.file_status));
    try stringify.objectField("metadata_lines");
    try stringify.beginArray();
    for (value.metadata_lines) |line| try stringify.write(line);
    try stringify.endArray();
    try stringify.objectField("hunks");
    try writeHunks(stringify, value.hunks);
    try stringify.objectField("locations");
    try writeLocations(stringify, allocator, value.locations);
    try stringify.objectField("before_guidance");
    try writeGuidance(stringify, allocator, value.before_guidance);
    try stringify.objectField("after_guidance");
    try writeGuidance(stringify, allocator, value.after_guidance);
    try stringify.objectField("coverage_spans");
    try stringify.beginArray();
    for (value.coverage_spans) |span| {
        try stringify.beginObject();
        try fieldUnsigned(stringify, "start", span.start);
        try fieldUnsigned(stringify, "end_exclusive", span.end_exclusive);
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.endObject();
}

fn writeHunks(stringify: *std.json.Stringify, hunks: []const protocol.ReviewHunk) WriteError!void {
    try stringify.beginArray();
    for (hunks) |hunk| {
        try stringify.beginObject();
        try fieldUnsigned(stringify, "old_start", hunk.old_start);
        try fieldUnsigned(stringify, "old_count", hunk.old_count);
        try fieldUnsigned(stringify, "new_start", hunk.new_start);
        try fieldUnsigned(stringify, "new_count", hunk.new_count);
        if (hunk.section) |section| try fieldString(stringify, "section", section);
        try stringify.objectField("lines");
        try stringify.beginArray();
        for (hunk.lines) |line| {
            try stringify.beginObject();
            try fieldString(stringify, "kind", diffLineKindName(line.kind));
            try fieldString(stringify, "text", line.text);
            try fieldString(stringify, "line_ending", lineEndingName(line.line_ending));
            if (line.before_location) |location| try fieldLocationId(stringify, "before_location", location);
            if (line.after_location) |location| try fieldLocationId(stringify, "after_location", location);
            try stringify.endObject();
        }
        try stringify.endArray();
        try stringify.endObject();
    }
    try stringify.endArray();
}

fn writeLocations(
    stringify: *std.json.Stringify,
    allocator: std.mem.Allocator,
    locations: []const protocol.ReviewLocation,
) WriteError!void {
    try stringify.beginArray();
    for (locations) |location| {
        try stringify.beginObject();
        try fieldLocationId(stringify, "location_id", location.location_id);
        try fieldRawPath(stringify, allocator, "path_bytes_b64", location.path_bytes);
        try fieldString(stringify, "side", sideName(location.side));
        try fieldUnsigned(stringify, "line", location.line);
        try stringify.endObject();
    }
    try stringify.endArray();
}

fn writeGuidance(
    stringify: *std.json.Stringify,
    allocator: std.mem.Allocator,
    guidance: []const protocol.Guidance,
) WriteError!void {
    try stringify.beginArray();
    for (guidance) |item| {
        try stringify.beginObject();
        try fieldString(stringify, "head_oid", item.head_oid);
        try fieldRawPath(stringify, allocator, "path_bytes_b64", item.path_bytes);
        try fieldString(stringify, "blob_oid", item.blob_oid);
        try fieldDigest(stringify, "content_digest", item.content_digest);
        try fieldString(stringify, "content", item.content);
        try stringify.endObject();
    }
    try stringify.endArray();
}

fn writeTarget(stringify: *std.json.Stringify, target: *const target_mod.CommittedReviewTarget) WriteError!void {
    try stringify.beginObject();
    try fieldString(stringify, "object_format", if (target.object_format == .sha1) "sha1" else "sha256");
    try fieldString(stringify, "source_kind", "branch_range");
    try fieldString(stringify, "base_oid", target.base_oid.slice());
    try fieldString(stringify, "head_oid", target.head_oid.slice());
    try fieldString(stringify, "diff_base_oid", target.diff_base_oid.slice());
    try stringify.endObject();
}

fn fieldRawPath(
    stringify: *std.json.Stringify,
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
) WriteError!void {
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(path.len));
    defer allocator.free(encoded);
    const written = std.base64.url_safe_no_pad.Encoder.encode(encoded, path);
    try fieldString(stringify, name, written);
}

fn fieldString(stringify: *std.json.Stringify, name: []const u8, value: []const u8) WriteError!void {
    try stringify.objectField(name);
    try stringify.write(value);
}

fn fieldUnsigned(stringify: *std.json.Stringify, name: []const u8, value: anytype) WriteError!void {
    try stringify.objectField(name);
    try stringify.write(value);
}

fn fieldDigest(stringify: *std.json.Stringify, name: []const u8, digest: identity.Sha256Digest) WriteError!void {
    const text = digest.canonical();
    try fieldString(stringify, name, &text);
}

fn fieldUnitId(stringify: *std.json.Stringify, name: []const u8, id: protocol.UnitId) WriteError!void {
    const text = id.canonical();
    try fieldString(stringify, name, &text);
}

fn fieldLocationId(stringify: *std.json.Stringify, name: []const u8, id: protocol.LocationId) WriteError!void {
    const text = id.canonical();
    try fieldString(stringify, name, &text);
}

fn fileStatusName(value: protocol.FileStatus) []const u8 {
    return switch (value) {
        .added => "added",
        .modified => "modified",
        .deleted => "deleted",
        .renamed => "renamed",
        .copied => "copied",
    };
}

fn diffLineKindName(value: protocol.DiffLineKind) []const u8 {
    return switch (value) {
        .context => "context",
        .removed => "removed",
        .added => "added",
    };
}

fn lineEndingName(value: protocol.LineEnding) []const u8 {
    return switch (value) {
        .lf => "lf",
        .crlf => "crlf",
        .none => "none",
    };
}

fn sideName(value: anchor.AnchorSide) []const u8 {
    return switch (value) {
        .before => "before",
        .after => "after",
    };
}

fn severityName(value: artifact.Severity) []const u8 {
    return switch (value) {
        .info => "info",
        .warning => "warning",
        .@"error" => "error",
    };
}

const fixture_path = "src/main.zig";
const fixture_lines = [_]protocol.DiffLine{
    .{
        .kind = .context,
        .text = "const std = @import(\"std\");",
        .line_ending = .lf,
        .before_location = .{ .side = .before, .ordinal = 1 },
        .after_location = .{ .side = .after, .ordinal = 1 },
    },
    .{
        .kind = .removed,
        .text = "old();",
        .line_ending = .lf,
        .before_location = .{ .side = .before, .ordinal = 2 },
    },
    .{
        .kind = .added,
        .text = "new();",
        .line_ending = .crlf,
        .after_location = .{ .side = .after, .ordinal = 2 },
    },
};
const fixture_hunks = [_]protocol.ReviewHunk{.{
    .old_start = 1,
    .old_count = 2,
    .new_start = 1,
    .new_count = 2,
    .section = "fn main()",
    .lines = &fixture_lines,
}};
const fixture_locations = [_]protocol.ReviewLocation{
    .{ .location_id = .{ .side = .before, .ordinal = 1 }, .path_bytes = fixture_path, .side = .before, .line = 1 },
    .{ .location_id = .{ .side = .before, .ordinal = 2 }, .path_bytes = fixture_path, .side = .before, .line = 2 },
    .{ .location_id = .{ .side = .after, .ordinal = 1 }, .path_bytes = fixture_path, .side = .after, .line = 1 },
    .{ .location_id = .{ .side = .after, .ordinal = 2 }, .path_bytes = fixture_path, .side = .after, .line = 2 },
};
const fixture_coverage = [_]protocol.CoverageSpan{.{ .start = 0, .end_exclusive = 128 }};
const fixture_metadata = [_][]const u8{"index 0000000..1111111 100644"};
const fixture_findings = [_]protocol.FindingCandidate{.{
    .start_location = .{ .side = .after, .ordinal = 2 },
    .end_location = .{ .side = .after, .ordinal = 2 },
    .severity = .warning,
    .title = "Check replacement",
    .body = "The replacement changes behavior.",
    .suggestion = "newSafe();",
}};

fn testTarget() target_mod.CommittedReviewTarget {
    return .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = target_mod.ObjectId.parse(.sha1, "0000000000000000000000000000000000000000") catch unreachable,
        .head_oid = target_mod.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111") catch unreachable,
        .diff_base_oid = target_mod.ObjectId.parse(.sha1, "0000000000000000000000000000000000000000") catch unreachable,
    };
}

fn testPlan() protocol.ReviewPlanSummary {
    return .{
        .schema_version = 1,
        .target = testTarget(),
        .projection_digest = identity.Sha256Digest.hash("projection"),
        .instruction_set_digest = identity.Sha256Digest.hash("instructions"),
        .unit_count = 1,
        .plan_digest = identity.Sha256Digest.hash("plan"),
        .limits = .v1,
    };
}

fn testUnit() protocol.ReviewUnit {
    return .{
        .schema_version = 1,
        .plan_digest = identity.Sha256Digest.hash("plan"),
        .unit_id = .{ .ordinal = 1 },
        .ordinal = 1,
        .unit_count = 1,
        .old_path_bytes = fixture_path,
        .new_path_bytes = fixture_path,
        .display_path = fixture_path,
        .file_status = .modified,
        .metadata_lines = &fixture_metadata,
        .hunks = &fixture_hunks,
        .locations = &fixture_locations,
        .before_guidance = &.{},
        .after_guidance = &.{},
        .coverage_spans = &fixture_coverage,
    };
}

fn readProtocolFixture(allocator: std.mem.Allocator, name: []const u8, maximum: usize) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "testdata/ai-review-producer-v1/protocol/{s}", .{name});
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(maximum));
}

fn expectUnitRoundTrip(allocator: std.mem.Allocator, value: *const protocol.ReviewUnit) !usize {
    const bytes = try value.writeCanonical(allocator);
    defer allocator.free(bytes);
    var parsed = try protocol.ReviewUnit.parseStrict(allocator, bytes);
    defer parsed.deinit();
    return bytes.len;
}

fn expectCapabilitiesRoundTrip(allocator: std.mem.Allocator, value: *const protocol.CapabilityResponse) !usize {
    const bytes = try value.writeCanonical(allocator);
    defer allocator.free(bytes);
    var parsed = try protocol.CapabilityResponse.parseStrict(allocator, bytes);
    defer parsed.deinit();
    return bytes.len;
}

fn expectCandidatePayloadRoundTrip(allocator: std.mem.Allocator, value: *const protocol.FindingCandidatePayload) !usize {
    const bytes = try value.writeCanonical(allocator);
    defer allocator.free(bytes);
    var parsed = try protocol.FindingCandidatePayload.parseStrict(allocator, bytes);
    defer parsed.deinit();
    return bytes.len;
}

const CandidateDocumentKind = enum { payload, batch };

fn writeCandidateDocumentAlloc(
    allocator: std.mem.Allocator,
    kind: CandidateDocumentKind,
    findings: []const protocol.FindingCandidate,
) ![]u8 {
    switch (kind) {
        .payload => {
            const value: protocol.FindingCandidatePayload = .{ .findings = findings };
            return value.writeCanonical(allocator);
        },
        .batch => {
            const value: protocol.FindingCandidateBatch = .{
                .schema_version = 1,
                .plan_digest = identity.Sha256Digest.hash("plan"),
                .unit_id = .{ .ordinal = 1 },
                .status = .reviewed,
                .findings = findings,
            };
            return value.writeCanonical(allocator);
        },
    }
}

fn candidateDocumentAtWireLimit(
    allocator: std.mem.Allocator,
    kind: CandidateDocumentKind,
) ![]u8 {
    const full_body = try allocator.alloc(u8, limits.max_body_bytes);
    defer allocator.free(full_body);
    @memset(full_body, 'b');
    const full_suggestion = try allocator.alloc(u8, limits.max_suggestion_bytes);
    defer allocator.free(full_suggestion);
    @memset(full_suggestion, 's');
    const tail_body = try allocator.alloc(u8, limits.max_body_bytes);
    defer allocator.free(tail_body);
    @memset(tail_body, 't');
    const tail_suggestion = try allocator.alloc(u8, limits.max_suggestion_bytes);
    defer allocator.free(tail_suggestion);
    @memset(tail_suggestion, 'u');

    var findings: [8]protocol.FindingCandidate = undefined;
    for (findings[0..7]) |*finding| {
        finding.* = fixture_findings[0];
        finding.body = full_body;
        finding.suggestion = full_suggestion;
    }
    findings[7] = fixture_findings[0];
    findings[7].body = tail_body[0..1];
    findings[7].suggestion = null;

    var probe = try writeCandidateDocumentAlloc(allocator, kind, &findings);
    var remaining = limits.max_candidate_batch_bytes - probe.len;
    allocator.free(probe);

    const body_growth = @min(remaining, limits.max_body_bytes - 1);
    const body_length = std.math.add(usize, 1, body_growth) catch return error.UnexpectedWireSize;
    findings[7].body = tail_body[0..body_length];
    remaining -= body_growth;
    if (remaining > 0) {
        findings[7].suggestion = tail_suggestion[0..1];
        probe = try writeCandidateDocumentAlloc(allocator, kind, &findings);
        if (probe.len > limits.max_candidate_batch_bytes) return error.UnexpectedWireSize;
        remaining = limits.max_candidate_batch_bytes - probe.len;
        allocator.free(probe);
        if (remaining > limits.max_suggestion_bytes - 1) return error.UnexpectedWireSize;
        const suggestion_length = std.math.add(usize, 1, remaining) catch return error.UnexpectedWireSize;
        findings[7].suggestion = tail_suggestion[0..suggestion_length];
    }
    const exact = try writeCandidateDocumentAlloc(allocator, kind, &findings);
    if (exact.len != limits.max_candidate_batch_bytes) {
        allocator.free(exact);
        return error.UnexpectedWireSize;
    }
    return exact;
}

test "AI review protocol canonical plan unit and candidate fixtures round trip" {
    const allocator = std.testing.allocator;
    const plan = testPlan();
    const plan_bytes = try plan.writeCanonical(allocator);
    defer allocator.free(plan_bytes);
    const plan_fixture = try readProtocolFixture(allocator, "plan.json", limits.max_plan_summary_bytes);
    defer allocator.free(plan_fixture);
    try std.testing.expectEqualStrings(plan_fixture, plan_bytes);
    var parsed_plan = try protocol.ReviewPlanSummary.parseStrict(allocator, plan_fixture);
    defer parsed_plan.deinit();
    try std.testing.expectEqual(@as(u16, 1), parsed_plan.value.unit_count);

    const unit = testUnit();
    const unit_bytes = try unit.writeCanonical(allocator);
    defer allocator.free(unit_bytes);
    const unit_fixture = try readProtocolFixture(allocator, "unit.json", limits.max_unit_bytes);
    defer allocator.free(unit_fixture);
    try std.testing.expectEqualStrings(unit_fixture, unit_bytes);
    var parsed_unit = try protocol.ReviewUnit.parseStrict(allocator, unit_fixture);
    defer parsed_unit.deinit();
    try std.testing.expectEqual(@as(usize, 4), parsed_unit.value.locations.len);
    try std.testing.expectEqual(protocol.LineEnding.crlf, parsed_unit.value.hunks[0].lines[2].line_ending);

    const payload: protocol.FindingCandidatePayload = .{ .findings = &fixture_findings };
    const payload_bytes = try payload.writeCanonical(allocator);
    defer allocator.free(payload_bytes);
    const payload_fixture = try readProtocolFixture(allocator, "candidate.json", limits.max_candidate_batch_bytes);
    defer allocator.free(payload_fixture);
    try std.testing.expectEqualStrings(payload_fixture, payload_bytes);
    var parsed_payload = try protocol.FindingCandidatePayload.parseStrict(allocator, payload_fixture);
    defer parsed_payload.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_payload.value.findings.len);

    const batch: protocol.FindingCandidateBatch = .{
        .schema_version = 1,
        .plan_digest = identity.Sha256Digest.hash("plan"),
        .unit_id = .{ .ordinal = 1 },
        .status = .reviewed,
        .findings = &fixture_findings,
    };
    const batch_bytes = try batch.writeCanonical(allocator);
    defer allocator.free(batch_bytes);
    const batch_fixture = try readProtocolFixture(allocator, "batch.json", limits.max_candidate_batch_bytes);
    defer allocator.free(batch_fixture);
    try std.testing.expectEqualStrings(batch_fixture, batch_bytes);
    var parsed_batch = try protocol.FindingCandidateBatch.parseStrict(allocator, batch_fixture);
    defer parsed_batch.deinit();
    try std.testing.expect(parsed_batch.value.unit_id.eql(.{ .ordinal = 1 }));
}

test "AI review protocol strict parsers reject unknown duplicate null and altered limits" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.UnknownField,
        protocol.FindingCandidatePayload.parseStrict(allocator, "{\"findings\":[],\"extra\":1}\n"),
    );
    try std.testing.expectError(
        error.DuplicateField,
        protocol.FindingCandidatePayload.parseStrict(allocator, "{\"findings\":[],\"findings\":[]}\n"),
    );
    try std.testing.expectError(
        error.InvalidType,
        protocol.FindingCandidatePayload.parseStrict(allocator, "{\"findings\":null}\n"),
    );
    try std.testing.expectError(
        error.InvalidJson,
        protocol.FindingCandidatePayload.parseStrict(allocator, "{\"findings\":[]}"),
    );

    const plan_fixture = try readProtocolFixture(allocator, "plan.json", limits.max_plan_summary_bytes);
    defer allocator.free(plan_fixture);
    const changed = try allocator.dupe(u8, plan_fixture);
    defer allocator.free(changed);
    const needle = "\"body_bytes\",\"value\":16384";
    const index = std.mem.indexOf(u8, changed, needle) orelse return error.MissingFixtureNeedle;
    changed[index + needle.len - 1] = '5';
    try std.testing.expectError(error.InvalidValue, protocol.ReviewPlanSummary.parseStrict(allocator, changed));
}

test "AI review protocol wire caps admit exact canonical documents and reject plus one" {
    const allocator = std.testing.allocator;

    const plan_limit = try allocator.alloc(u8, limits.max_plan_summary_bytes + 1);
    defer allocator.free(plan_limit);
    @memset(plan_limit, ' ');
    plan_limit[0] = '{';
    try std.testing.expectError(
        error.InvalidJson,
        protocol.ReviewPlanSummary.parseStrict(allocator, plan_limit[0..limits.max_plan_summary_bytes]),
    );
    try std.testing.expectError(error.ArtifactTooLarge, protocol.ReviewPlanSummary.parseStrict(allocator, plan_limit));

    const metadata_line = try allocator.alloc(u8, limits.max_metadata_line_bytes);
    defer allocator.free(metadata_line);
    @memset(metadata_line, 'm');
    const metadata_tail = try allocator.alloc(u8, limits.max_metadata_line_bytes);
    defer allocator.free(metadata_tail);
    @memset(metadata_tail, 'n');
    var metadata: [16][]const u8 = undefined;
    @memset(metadata[0..15], metadata_line);
    var unit = testUnit();
    unit.metadata_lines = metadata[0..15];
    const unit_probe = try unit.writeCanonical(allocator);
    const unit_remaining = limits.max_unit_bytes - unit_probe.len;
    allocator.free(unit_probe);
    if (unit_remaining < 3 or unit_remaining - 3 > metadata_tail.len) return error.UnexpectedWireSize;
    metadata[15] = metadata_tail[0 .. unit_remaining - 3];
    unit.metadata_lines = &metadata;
    const exact_unit = try unit.writeCanonical(allocator);
    defer allocator.free(exact_unit);
    try std.testing.expectEqual(limits.max_unit_bytes, exact_unit.len);
    var parsed_unit = try protocol.ReviewUnit.parseStrict(allocator, exact_unit);
    parsed_unit.deinit();
    const oversized_unit = try std.mem.concat(allocator, u8, &.{ exact_unit, " " });
    defer allocator.free(oversized_unit);
    try std.testing.expectError(error.ArtifactTooLarge, protocol.ReviewUnit.parseStrict(allocator, oversized_unit));

    const exact_payload = try candidateDocumentAtWireLimit(allocator, .payload);
    defer allocator.free(exact_payload);
    var parsed_payload = try protocol.FindingCandidatePayload.parseStrict(allocator, exact_payload);
    parsed_payload.deinit();
    const oversized_payload = try std.mem.concat(allocator, u8, &.{ exact_payload, " " });
    defer allocator.free(oversized_payload);
    try std.testing.expectError(
        error.ArtifactTooLarge,
        protocol.FindingCandidatePayload.parseStrict(allocator, oversized_payload),
    );

    const exact_batch = try candidateDocumentAtWireLimit(allocator, .batch);
    defer allocator.free(exact_batch);
    var parsed_batch = try protocol.FindingCandidateBatch.parseStrict(allocator, exact_batch);
    parsed_batch.deinit();
    const oversized_batch = try std.mem.concat(allocator, u8, &.{ exact_batch, " " });
    defer allocator.free(oversized_batch);
    try std.testing.expectError(error.ArtifactTooLarge, protocol.FindingCandidateBatch.parseStrict(allocator, oversized_batch));

    var name_storage: [limits.max_capabilities][limits.max_capability_name_bytes]u8 = undefined;
    var capabilities: [limits.max_capabilities]protocol.Capability = undefined;
    var versions: [limits.max_capability_versions]u16 = undefined;
    for (&versions, 0..) |*version, index| version.* = @intCast(index + 1);
    for (&name_storage, 0..) |*storage, index| {
        storage.* = [_]u8{'x'} ** limits.max_capability_name_bytes;
        storage[0] = 'c';
        storage[1] = @intCast('0' + (index / 100) % 10);
        storage[2] = @intCast('0' + (index / 10) % 10);
        storage[3] = @intCast('0' + index % 10);
        capabilities[index] = .{ .name = storage, .versions = &versions };
    }
    const response: protocol.CapabilityResponse = .{
        .schema_version = 1,
        .status = .ok,
        .gitframe_version = "v",
        .capabilities = &capabilities,
    };
    const capability_probe = try response.writeCanonical(allocator);
    var capability_remaining = limits.max_capabilities_bytes - capability_probe.len;
    allocator.free(capability_probe);
    for (&name_storage) |*storage| {
        for (storage[4..]) |*byte| {
            if (capability_remaining == 0) break;
            byte.* = '\\';
            capability_remaining -= 1;
        }
        if (capability_remaining == 0) break;
    }
    if (capability_remaining != 0) return error.UnexpectedWireSize;
    const exact_capabilities = try response.writeCanonical(allocator);
    defer allocator.free(exact_capabilities);
    try std.testing.expectEqual(limits.max_capabilities_bytes, exact_capabilities.len);
    var parsed_capabilities = try protocol.CapabilityResponse.parseStrict(allocator, exact_capabilities);
    parsed_capabilities.deinit();
    const oversized_capabilities = try std.mem.concat(allocator, u8, &.{ exact_capabilities, " " });
    defer allocator.free(oversized_capabilities);
    try std.testing.expectError(
        error.ArtifactTooLarge,
        protocol.CapabilityResponse.parseStrict(allocator, oversized_capabilities),
    );
}

test "AI review protocol public scalar and feasible collection bounds are exact" {
    const allocator = std.testing.allocator;
    var unit = testUnit();

    const display_path = try allocator.alloc(u8, limits.max_display_path_bytes + 1);
    defer allocator.free(display_path);
    @memset(display_path, 'd');
    unit.display_path = display_path[0..limits.max_display_path_bytes];
    _ = try expectUnitRoundTrip(allocator, &unit);
    unit.display_path = display_path;
    try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));

    const metadata_line = try allocator.alloc(u8, limits.max_metadata_line_bytes + 1);
    defer allocator.free(metadata_line);
    @memset(metadata_line, 'm');
    unit = testUnit();
    unit.metadata_lines = &.{metadata_line[0..limits.max_metadata_line_bytes]};
    _ = try expectUnitRoundTrip(allocator, &unit);
    unit.metadata_lines = &.{metadata_line};
    try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));

    const section = try allocator.alloc(u8, limits.max_hunk_section_bytes + 1);
    defer allocator.free(section);
    @memset(section, 's');
    var hunks = fixture_hunks;
    hunks[0].section = section[0..limits.max_hunk_section_bytes];
    unit = testUnit();
    unit.hunks = &hunks;
    _ = try expectUnitRoundTrip(allocator, &unit);
    hunks[0].section = section;
    try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));

    const diff_text = try allocator.alloc(u8, limits.max_diff_line_bytes + 1);
    defer allocator.free(diff_text);
    @memset(diff_text, 'l');
    var lines = fixture_lines;
    lines[0].text = diff_text[0..limits.max_diff_line_bytes];
    hunks = fixture_hunks;
    hunks[0].lines = &lines;
    unit = testUnit();
    unit.hunks = &hunks;
    _ = try expectUnitRoundTrip(allocator, &unit);
    lines[0].text = diff_text;
    try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));

    const raw_path = try allocator.alloc(u8, limits.max_raw_path_bytes + 1);
    defer allocator.free(raw_path);
    @memset(raw_path, 0xff);
    const added_line = [_]protocol.DiffLine{.{
        .kind = .added,
        .text = "added",
        .line_ending = .none,
        .after_location = .{ .side = .after, .ordinal = 1 },
    }};
    const added_hunk = [_]protocol.ReviewHunk{.{
        .old_start = 0,
        .old_count = 0,
        .new_start = 1,
        .new_count = 1,
        .lines = &added_line,
    }};
    var added_location = [_]protocol.ReviewLocation{.{
        .location_id = .{ .side = .after, .ordinal = 1 },
        .path_bytes = raw_path[0..limits.max_raw_path_bytes],
        .side = .after,
        .line = 1,
    }};
    unit = testUnit();
    unit.old_path_bytes = null;
    unit.new_path_bytes = raw_path[0..limits.max_raw_path_bytes];
    unit.file_status = .added;
    unit.metadata_lines = &.{};
    unit.hunks = &added_hunk;
    unit.locations = &added_location;
    _ = try expectUnitRoundTrip(allocator, &unit);
    unit.new_path_bytes = raw_path;
    added_location[0].path_bytes = raw_path;
    try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));

    const guidance_content = try allocator.alloc(u8, limits.max_guidance_file_bytes + 1);
    defer allocator.free(guidance_content);
    @memset(guidance_content, 'g');
    var guidance_item: protocol.Guidance = .{
        .head_oid = "1111111111111111111111111111111111111111",
        .path_bytes = "AGENTS.md",
        .blob_oid = "2222222222222222222222222222222222222222",
        .content_digest = identity.Sha256Digest.hash(guidance_content[0..limits.max_guidance_file_bytes]),
        .content = guidance_content[0..limits.max_guidance_file_bytes],
    };
    unit = testUnit();
    unit.before_guidance = &.{guidance_item};
    _ = try expectUnitRoundTrip(allocator, &unit);
    guidance_item.content = guidance_content;
    guidance_item.content_digest = identity.Sha256Digest.hash(guidance_content);
    unit.before_guidance = &.{guidance_item};
    try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));

    const metadata_lines = try allocator.alloc([]const u8, limits.max_metadata_lines_per_unit + 1);
    defer allocator.free(metadata_lines);
    @memset(metadata_lines, "");
    unit = testUnit();
    unit.metadata_lines = metadata_lines[0..limits.max_metadata_lines_per_unit];
    _ = try expectUnitRoundTrip(allocator, &unit);
    unit.metadata_lines = metadata_lines;
    try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));

    var guidance_paths: [limits.max_guidance_path_depth + 1][80]u8 = undefined;
    var guidance_items: [limits.max_guidance_path_depth + 1]protocol.Guidance = undefined;
    for (&guidance_paths, 0..) |*path, depth| {
        var length: usize = 0;
        for (0..depth) |_| {
            path[length] = 'd';
            path[length + 1] = '/';
            length += 2;
        }
        @memcpy(path[length .. length + "AGENTS.md".len], "AGENTS.md");
        length += "AGENTS.md".len;
        guidance_items[depth] = .{
            .head_oid = "1111111111111111111111111111111111111111",
            .path_bytes = path[0..length],
            .blob_oid = "2222222222222222222222222222222222222222",
            .content_digest = identity.Sha256Digest.hash(""),
            .content = "",
        };
    }
    var exact_depth_path_buffer: [80]u8 = undefined;
    var exact_depth_path_length: usize = 0;
    for (0..limits.max_guidance_path_depth) |_| {
        exact_depth_path_buffer[exact_depth_path_length] = 'd';
        exact_depth_path_buffer[exact_depth_path_length + 1] = '/';
        exact_depth_path_length += 2;
    }
    @memcpy(exact_depth_path_buffer[exact_depth_path_length .. exact_depth_path_length + "file.zig".len], "file.zig");
    exact_depth_path_length += "file.zig".len;
    const exact_depth_path = exact_depth_path_buffer[0..exact_depth_path_length];
    var deep_locations = fixture_locations;
    for (&deep_locations) |*location| location.path_bytes = exact_depth_path;
    unit = testUnit();
    unit.old_path_bytes = exact_depth_path;
    unit.new_path_bytes = exact_depth_path;
    unit.locations = &deep_locations;
    unit.before_guidance = guidance_items[0..limits.max_guidance_path_depth];
    unit.after_guidance = guidance_items[0..limits.max_guidance_path_depth];
    _ = try expectUnitRoundTrip(allocator, &unit);
    // Repeating one full root-plus-32 chain on both sides is 33 unique sources,
    // not 66 serialized occurrences.
    unit.before_guidance = &guidance_items;
    unit.after_guidance = &guidance_items;
    _ = try expectUnitRoundTrip(allocator, &unit);
    unit.after_guidance = &.{};
    _ = try expectUnitRoundTrip(allocator, &unit);

    var alternate_guidance_paths: [limits.max_guidance_path_depth + 1][80]u8 = undefined;
    var alternate_guidance_items: [limits.max_guidance_path_depth + 1]protocol.Guidance = undefined;
    for (&alternate_guidance_paths, 0..) |*path, depth| {
        var length: usize = 0;
        for (0..depth) |_| {
            path[length] = 'e';
            path[length + 1] = '/';
            length += 2;
        }
        @memcpy(path[length .. length + "AGENTS.md".len], "AGENTS.md");
        length += "AGENTS.md".len;
        alternate_guidance_items[depth] = .{
            .head_oid = "1111111111111111111111111111111111111111",
            .path_bytes = path[0..length],
            .blob_oid = "2222222222222222222222222222222222222222",
            .content_digest = identity.Sha256Digest.hash(""),
            .content = "",
        };
    }
    var alternate_depth_path_buffer: [80]u8 = undefined;
    var alternate_depth_path_length: usize = 0;
    for (0..limits.max_guidance_path_depth) |_| {
        alternate_depth_path_buffer[alternate_depth_path_length] = 'e';
        alternate_depth_path_buffer[alternate_depth_path_length + 1] = '/';
        alternate_depth_path_length += 2;
    }
    @memcpy(alternate_depth_path_buffer[alternate_depth_path_length .. alternate_depth_path_length + "file.zig".len], "file.zig");
    alternate_depth_path_length += "file.zig".len;
    const alternate_depth_path = alternate_depth_path_buffer[0..alternate_depth_path_length];
    var union_locations = fixture_locations;
    for (&union_locations) |*location| {
        location.path_bytes = switch (location.side) {
            .before => exact_depth_path,
            .after => alternate_depth_path,
        };
    }
    unit = testUnit();
    unit.old_path_bytes = exact_depth_path;
    unit.new_path_bytes = alternate_depth_path;
    unit.file_status = .renamed;
    unit.locations = &union_locations;
    // The two distinct chains share only root: 32 + 33 - 1 is the exact 64
    // unique-source limit, while 33 + 33 - 1 is 65 and must fail.
    unit.before_guidance = guidance_items[0..limits.max_guidance_path_depth];
    unit.after_guidance = &alternate_guidance_items;
    _ = try expectUnitRoundTrip(allocator, &unit);
    unit.before_guidance = &guidance_items;
    try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));

    var plus_one_depth_path_buffer: [80]u8 = undefined;
    var plus_one_depth_path_length: usize = 0;
    for (0..limits.max_guidance_path_depth + 1) |_| {
        plus_one_depth_path_buffer[plus_one_depth_path_length] = 'd';
        plus_one_depth_path_buffer[plus_one_depth_path_length + 1] = '/';
        plus_one_depth_path_length += 2;
    }
    @memcpy(plus_one_depth_path_buffer[plus_one_depth_path_length .. plus_one_depth_path_length + "file.zig".len], "file.zig");
    plus_one_depth_path_length += "file.zig".len;
    const plus_one_depth_path = plus_one_depth_path_buffer[0..plus_one_depth_path_length];
    for (&deep_locations) |*location| location.path_bytes = plus_one_depth_path;
    unit.old_path_bytes = plus_one_depth_path;
    unit.new_path_bytes = plus_one_depth_path;
    unit.file_status = .modified;
    unit.locations = &deep_locations;
    unit.before_guidance = &.{};
    unit.after_guidance = &.{};
    try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));

    const guidance_tail = try allocator.alloc(u8, limits.max_guidance_per_unit_bytes - limits.max_guidance_file_bytes + 1);
    defer allocator.free(guidance_tail);
    @memset(guidance_tail, 't');
    var aggregate_guidance = [_]protocol.Guidance{
        .{
            .head_oid = "1111111111111111111111111111111111111111",
            .path_bytes = "AGENTS.md",
            .blob_oid = "2222222222222222222222222222222222222222",
            .content_digest = identity.Sha256Digest.hash(guidance_content[0..limits.max_guidance_file_bytes]),
            .content = guidance_content[0..limits.max_guidance_file_bytes],
        },
        .{
            .head_oid = "1111111111111111111111111111111111111111",
            .path_bytes = "src/AGENTS.md",
            .blob_oid = "3333333333333333333333333333333333333333",
            .content_digest = identity.Sha256Digest.hash(guidance_tail[0 .. guidance_tail.len - 1]),
            .content = guidance_tail[0 .. guidance_tail.len - 1],
        },
    };
    unit = testUnit();
    unit.before_guidance = &aggregate_guidance;
    _ = try expectUnitRoundTrip(allocator, &unit);
    aggregate_guidance[1].content = guidance_tail;
    aggregate_guidance[1].content_digest = identity.Sha256Digest.hash(guidance_tail);
    try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));

    var capability_names: [limits.max_capabilities + 1][4]u8 = undefined;
    var capabilities: [limits.max_capabilities + 1]protocol.Capability = undefined;
    const one_version = [_]u16{1};
    for (&capability_names, 0..) |*name, index| {
        name.* = .{
            'c',
            @intCast('0' + (index / 100) % 10),
            @intCast('0' + (index / 10) % 10),
            @intCast('0' + index % 10),
        };
        capabilities[index] = .{ .name = name, .versions = &one_version };
    }
    var response: protocol.CapabilityResponse = .{
        .schema_version = 1,
        .status = .ok,
        .gitframe_version = "v",
        .capabilities = capabilities[0..limits.max_capabilities],
    };
    _ = try expectCapabilitiesRoundTrip(allocator, &response);
    response.capabilities = &capabilities;
    try std.testing.expectError(error.LimitExceeded, response.writeCanonical(allocator));

    const capability_name = try allocator.alloc(u8, limits.max_capability_name_bytes + 1);
    defer allocator.free(capability_name);
    @memset(capability_name, 'n');
    var single_capability = [_]protocol.Capability{.{
        .name = capability_name[0..limits.max_capability_name_bytes],
        .versions = &one_version,
    }};
    response.capabilities = &single_capability;
    _ = try expectCapabilitiesRoundTrip(allocator, &response);
    single_capability[0].name = capability_name;
    try std.testing.expectError(error.LimitExceeded, response.writeCanonical(allocator));

    var capability_versions: [limits.max_capability_versions + 1]u16 = undefined;
    for (&capability_versions, 0..) |*version, index| version.* = @intCast(index + 1);
    single_capability[0].name = "capability";
    single_capability[0].versions = capability_versions[0..limits.max_capability_versions];
    _ = try expectCapabilitiesRoundTrip(allocator, &response);
    single_capability[0].versions = &capability_versions;
    try std.testing.expectError(error.LimitExceeded, response.writeCanonical(allocator));

    const diagnostic_version = try allocator.alloc(u8, limits.max_gitframe_version_bytes + 1);
    defer allocator.free(diagnostic_version);
    @memset(diagnostic_version, 'v');
    single_capability[0].versions = &one_version;
    response.gitframe_version = diagnostic_version[0..limits.max_gitframe_version_bytes];
    _ = try expectCapabilitiesRoundTrip(allocator, &response);
    response.gitframe_version = diagnostic_version;
    try std.testing.expectError(error.LimitExceeded, response.writeCanonical(allocator));
}

test "AI review protocol layered collection caps fail at their owning boundary" {
    const allocator = std.testing.allocator;
    const path = "f";

    {
        const lines = try allocator.alloc(protocol.DiffLine, limits.max_hunks + 1);
        defer allocator.free(lines);
        const hunks = try allocator.alloc(protocol.ReviewHunk, limits.max_hunks + 1);
        defer allocator.free(hunks);
        const locations = try allocator.alloc(protocol.ReviewLocation, limits.max_hunks * 2);
        defer allocator.free(locations);
        for (lines, 0..) |*line, index| {
            const ordinal: u16 = @intCast(index + 1);
            line.* = .{
                .kind = .context,
                .text = "x",
                .line_ending = .lf,
                .before_location = .{ .side = .before, .ordinal = ordinal },
                .after_location = .{ .side = .after, .ordinal = ordinal },
            };
            hunks[index] = .{
                .old_start = @intCast(index + 1),
                .old_count = 1,
                .new_start = @intCast(index + 1),
                .new_count = 1,
                .lines = lines[index .. index + 1],
            };
            if (index < limits.max_hunks) {
                locations[index] = .{
                    .location_id = .{ .side = .before, .ordinal = ordinal },
                    .path_bytes = path,
                    .side = .before,
                    .line = @intCast(index + 1),
                };
                locations[limits.max_hunks + index] = .{
                    .location_id = .{ .side = .after, .ordinal = ordinal },
                    .path_bytes = path,
                    .side = .after,
                    .line = @intCast(index + 1),
                };
            }
        }
        var unit = testUnit();
        unit.old_path_bytes = path;
        unit.new_path_bytes = path;
        unit.hunks = hunks[0..limits.max_hunks];
        unit.locations = locations;
        try std.testing.expectError(error.ArtifactTooLarge, unit.writeCanonical(allocator));
        unit.hunks = hunks;
        try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));
    }

    {
        const locations = try allocator.alloc(protocol.ReviewLocation, limits.max_locations_per_side + 1);
        defer allocator.free(locations);
        const lines = try allocator.alloc(protocol.DiffLine, limits.max_locations_per_side);
        defer allocator.free(lines);
        for (locations, 0..) |*location, index| {
            const ordinal: u16 = @intCast(index + 1);
            location.* = .{
                .location_id = .{ .side = .after, .ordinal = ordinal },
                .path_bytes = path,
                .side = .after,
                .line = @intCast(index + 1),
            };
            if (index < lines.len) {
                lines[index] = .{
                    .kind = .added,
                    .text = "x",
                    .line_ending = .lf,
                    .after_location = .{ .side = .after, .ordinal = ordinal },
                };
            }
        }
        const hunk = [_]protocol.ReviewHunk{.{
            .old_start = 0,
            .old_count = 0,
            .new_start = 1,
            .new_count = limits.max_locations_per_side,
            .lines = lines,
        }};
        var unit = testUnit();
        unit.old_path_bytes = null;
        unit.new_path_bytes = path;
        unit.file_status = .added;
        unit.hunks = &hunk;
        unit.locations = locations[0..limits.max_locations_per_side];
        try std.testing.expectError(error.ArtifactTooLarge, unit.writeCanonical(allocator));
        unit.locations = locations;
        try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));
    }

    {
        try std.testing.expectEqual(limits.max_locations_per_side * 2, limits.max_lines_per_unit);
        const lines = try allocator.alloc(protocol.DiffLine, limits.max_lines_per_unit + 1);
        defer allocator.free(lines);
        const locations = try allocator.alloc(protocol.ReviewLocation, limits.max_lines_per_unit);
        defer allocator.free(locations);
        for (0..limits.max_locations_per_side) |index| {
            const ordinal: u16 = @intCast(index + 1);
            lines[index] = .{
                .kind = .removed,
                .text = "x",
                .line_ending = .lf,
                .before_location = .{ .side = .before, .ordinal = ordinal },
            };
            lines[limits.max_locations_per_side + index] = .{
                .kind = .added,
                .text = "y",
                .line_ending = .lf,
                .after_location = .{ .side = .after, .ordinal = ordinal },
            };
            locations[index] = .{
                .location_id = .{ .side = .before, .ordinal = ordinal },
                .path_bytes = path,
                .side = .before,
                .line = @intCast(index + 1),
            };
            locations[limits.max_locations_per_side + index] = .{
                .location_id = .{ .side = .after, .ordinal = ordinal },
                .path_bytes = path,
                .side = .after,
                .line = @intCast(index + 1),
            };
        }
        const exact_hunk = [_]protocol.ReviewHunk{.{
            .old_start = 1,
            .old_count = limits.max_locations_per_side,
            .new_start = 1,
            .new_count = limits.max_locations_per_side,
            .lines = lines[0..limits.max_lines_per_unit],
        }};
        var unit = testUnit();
        unit.old_path_bytes = path;
        unit.new_path_bytes = path;
        unit.hunks = &exact_hunk;
        unit.locations = locations;
        try std.testing.expectError(error.ArtifactTooLarge, unit.writeCanonical(allocator));

        const oversized_hunk = [_]protocol.ReviewHunk{.{
            .old_start = 1,
            .old_count = 1,
            .new_start = 1,
            .new_count = 1,
            .lines = lines,
        }};
        unit = testUnit();
        unit.hunks = &oversized_hunk;
        try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));
    }

    {
        const spans = try allocator.alloc(protocol.CoverageSpan, limits.max_coverage_spans_per_unit + 1);
        defer allocator.free(spans);
        for (spans, 0..) |*span, index| {
            span.* = .{ .start = @intCast(index), .end_exclusive = @intCast(index + 1) };
        }
        var unit = testUnit();
        unit.coverage_spans = spans[0..limits.max_coverage_spans_per_unit];
        try std.testing.expectError(error.ArtifactTooLarge, unit.writeCanonical(allocator));
        unit.coverage_spans = spans;
        try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));
    }
}

test "AI review protocol finite text and finding bounds accept exact and reject plus one" {
    const allocator = std.testing.allocator;
    const title = try allocator.alloc(u8, limits.max_title_bytes + 1);
    defer allocator.free(title);
    @memset(title, 't');
    const body = try allocator.alloc(u8, limits.max_body_bytes + 1);
    defer allocator.free(body);
    @memset(body, 'b');
    const suggestion = try allocator.alloc(u8, limits.max_suggestion_bytes + 1);
    defer allocator.free(suggestion);
    @memset(suggestion, 's');

    var candidate = fixture_findings[0];
    candidate.title = title[0..limits.max_title_bytes];
    candidate.body = body[0..limits.max_body_bytes];
    candidate.suggestion = suggestion[0..limits.max_suggestion_bytes];
    var payload: protocol.FindingCandidatePayload = .{ .findings = &.{candidate} };
    _ = try expectCandidatePayloadRoundTrip(allocator, &payload);
    candidate.title = title;
    payload.findings = &.{candidate};
    try std.testing.expectError(error.LimitExceeded, payload.writeCanonical(allocator));
    candidate.title = "title";
    candidate.body = body;
    payload.findings = &.{candidate};
    try std.testing.expectError(error.LimitExceeded, payload.writeCanonical(allocator));
    candidate.body = "body";
    candidate.suggestion = suggestion;
    payload.findings = &.{candidate};
    try std.testing.expectError(error.LimitExceeded, payload.writeCanonical(allocator));

    const exact_findings = try allocator.alloc(protocol.FindingCandidate, limits.max_findings_per_unit + 1);
    defer allocator.free(exact_findings);
    @memset(exact_findings, fixture_findings[0]);
    payload.findings = exact_findings[0..limits.max_findings_per_unit];
    _ = try expectCandidatePayloadRoundTrip(allocator, &payload);
    payload.findings = exact_findings;
    try std.testing.expectError(error.LimitExceeded, payload.writeCanonical(allocator));
}

test "AI review protocol plan and unit identity bounds are exact" {
    const allocator = std.testing.allocator;
    var plan = testPlan();
    plan.unit_count = 0;
    const zero = try plan.writeCanonical(allocator);
    defer allocator.free(zero);
    var parsed_zero = try protocol.ReviewPlanSummary.parseStrict(allocator, zero);
    parsed_zero.deinit();
    plan.unit_count = limits.max_review_units;
    const exact = try plan.writeCanonical(allocator);
    defer allocator.free(exact);
    var parsed = try protocol.ReviewPlanSummary.parseStrict(allocator, exact);
    parsed.deinit();
    plan.unit_count += 1;
    try std.testing.expectError(error.LimitExceeded, plan.writeCanonical(allocator));

    var unit = testUnit();
    unit.unit_id = .{ .ordinal = limits.max_review_units };
    unit.ordinal = limits.max_review_units;
    unit.unit_count = limits.max_review_units;
    _ = try expectUnitRoundTrip(allocator, &unit);
    unit.unit_count = 0;
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));
}

test "AI review protocol guidance digest binds exact content bytes" {
    const allocator = std.testing.allocator;
    const content = "root guidance\r\nexact bytes\n";
    var guidance: protocol.Guidance = .{
        .head_oid = "1111111111111111111111111111111111111111",
        .path_bytes = "AGENTS.md",
        .blob_oid = "2222222222222222222222222222222222222222",
        .content_digest = identity.Sha256Digest.hash(content),
        .content = content,
    };
    var unit = testUnit();
    unit.before_guidance = &.{guidance};

    const exact = try unit.writeCanonical(allocator);
    defer allocator.free(exact);
    var parsed = try protocol.ReviewUnit.parseStrict(allocator, exact);
    parsed.deinit();

    const canonical_digest = guidance.content_digest.canonical();
    const digest_index = std.mem.indexOf(u8, exact, &canonical_digest) orelse return error.MissingFixtureNeedle;
    exact[digest_index + 7] = if (exact[digest_index + 7] == '0') '1' else '0';
    try std.testing.expectError(error.InvalidValue, protocol.ReviewUnit.parseStrict(allocator, exact));

    guidance.content_digest = identity.Sha256Digest.hash("different content");
    unit.before_guidance = &.{guidance};
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    guidance.content_digest = identity.Sha256Digest.hash(content);
    guidance.path_bytes = "README.md";
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    const root_guidance: protocol.Guidance = .{
        .head_oid = "1111111111111111111111111111111111111111",
        .path_bytes = "AGENTS.md",
        .blob_oid = "2222222222222222222222222222222222222222",
        .content_digest = identity.Sha256Digest.hash("root"),
        .content = "root",
    };
    const nested_guidance: protocol.Guidance = .{
        .head_oid = "1111111111111111111111111111111111111111",
        .path_bytes = "src/AGENTS.md",
        .blob_oid = "3333333333333333333333333333333333333333",
        .content_digest = identity.Sha256Digest.hash("nested"),
        .content = "nested",
    };
    unit.before_guidance = &.{ root_guidance, nested_guidance };
    _ = try expectUnitRoundTrip(allocator, &unit);
    unit.before_guidance = &.{ nested_guidance, root_guidance };
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    var sibling_guidance = nested_guidance;
    sibling_guidance.path_bytes = "lib/AGENTS.md";
    unit.before_guidance = &.{sibling_guidance};
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    var unrelated_guidance = nested_guidance;
    unrelated_guidance.path_bytes = "src/main/AGENTS.md";
    unit.before_guidance = &.{unrelated_guidance};
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    var foreign_head = nested_guidance;
    foreign_head.head_oid = "4444444444444444444444444444444444444444";
    unit.before_guidance = &.{root_guidance};
    unit.after_guidance = &.{foreign_head};
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    unit.before_guidance = &.{root_guidance};
    unit.after_guidance = &.{root_guidance};
    _ = try expectUnitRoundTrip(allocator, &unit);

    // A repeated exact-head/path key is one source and therefore must retain
    // one exact blob, digest, and content identity across both chains.
    var conflicting_blob = root_guidance;
    conflicting_blob.blob_oid = "4444444444444444444444444444444444444444";
    unit.after_guidance = &.{conflicting_blob};
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    var conflicting_content = root_guidance;
    conflicting_content.content = "different root";
    conflicting_content.content_digest = identity.Sha256Digest.hash(conflicting_content.content);
    unit.after_guidance = &.{conflicting_content};
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    unit.after_guidance = &.{root_guidance};
    const repeated_source = try unit.writeCanonical(allocator);
    defer allocator.free(repeated_source);
    const repeated_blob_index = std.mem.lastIndexOf(u8, repeated_source, root_guidance.blob_oid) orelse
        return error.MissingFixtureNeedle;
    repeated_source[repeated_blob_index] = '4';
    try std.testing.expectError(error.InvalidValue, protocol.ReviewUnit.parseStrict(allocator, repeated_source));

    const added_lines = [_]protocol.DiffLine{.{
        .kind = .added,
        .text = "added",
        .line_ending = .lf,
        .after_location = .{ .side = .after, .ordinal = 1 },
    }};
    const added_hunks = [_]protocol.ReviewHunk{.{
        .old_start = 0,
        .old_count = 0,
        .new_start = 1,
        .new_count = 1,
        .lines = &added_lines,
    }};
    const added_locations = [_]protocol.ReviewLocation{.{
        .location_id = .{ .side = .after, .ordinal = 1 },
        .path_bytes = fixture_path,
        .side = .after,
        .line = 1,
    }};
    var added_unit = testUnit();
    added_unit.old_path_bytes = null;
    added_unit.file_status = .added;
    added_unit.metadata_lines = &.{};
    added_unit.hunks = &added_hunks;
    added_unit.locations = &added_locations;
    _ = try expectUnitRoundTrip(allocator, &added_unit);
    added_unit.before_guidance = &.{root_guidance};
    try std.testing.expectError(error.InvalidValue, added_unit.writeCanonical(allocator));

    const deleted_lines = [_]protocol.DiffLine{.{
        .kind = .removed,
        .text = "deleted",
        .line_ending = .lf,
        .before_location = .{ .side = .before, .ordinal = 1 },
    }};
    const deleted_hunks = [_]protocol.ReviewHunk{.{
        .old_start = 1,
        .old_count = 1,
        .new_start = 0,
        .new_count = 0,
        .lines = &deleted_lines,
    }};
    const deleted_locations = [_]protocol.ReviewLocation{.{
        .location_id = .{ .side = .before, .ordinal = 1 },
        .path_bytes = fixture_path,
        .side = .before,
        .line = 1,
    }};
    var deleted_unit = testUnit();
    deleted_unit.new_path_bytes = null;
    deleted_unit.file_status = .deleted;
    deleted_unit.metadata_lines = &.{};
    deleted_unit.hunks = &deleted_hunks;
    deleted_unit.locations = &deleted_locations;
    _ = try expectUnitRoundTrip(allocator, &deleted_unit);
    deleted_unit.after_guidance = &.{root_guidance};
    try std.testing.expectError(error.InvalidValue, deleted_unit.writeCanonical(allocator));
}

test "AI review protocol hunk spans are strictly source ordered" {
    const allocator = std.testing.allocator;
    const path = "src/main.zig";
    const lines = [_]protocol.DiffLine{
        .{
            .kind = .context,
            .text = "first",
            .line_ending = .lf,
            .before_location = .{ .side = .before, .ordinal = 1 },
            .after_location = .{ .side = .after, .ordinal = 1 },
        },
        .{
            .kind = .context,
            .text = "second",
            .line_ending = .lf,
            .before_location = .{ .side = .before, .ordinal = 2 },
            .after_location = .{ .side = .after, .ordinal = 2 },
        },
    };
    var hunks = [_]protocol.ReviewHunk{
        .{ .old_start = 10, .old_count = 1, .new_start = 10, .new_count = 1, .lines = lines[0..1] },
        .{ .old_start = 20, .old_count = 1, .new_start = 20, .new_count = 1, .lines = lines[1..2] },
    };
    var locations = [_]protocol.ReviewLocation{
        .{ .location_id = .{ .side = .before, .ordinal = 1 }, .path_bytes = path, .side = .before, .line = 10 },
        .{ .location_id = .{ .side = .before, .ordinal = 2 }, .path_bytes = path, .side = .before, .line = 20 },
        .{ .location_id = .{ .side = .after, .ordinal = 1 }, .path_bytes = path, .side = .after, .line = 10 },
        .{ .location_id = .{ .side = .after, .ordinal = 2 }, .path_bytes = path, .side = .after, .line = 20 },
    };
    var unit = testUnit();
    unit.hunks = &hunks;
    unit.locations = &locations;
    try std.testing.expect((try expectUnitRoundTrip(allocator, &unit)) <= limits.max_unit_bytes);

    const canonical = try unit.writeCanonical(allocator);
    defer allocator.free(canonical);
    const second_hunk = std.mem.indexOf(u8, canonical, "\"old_start\":20") orelse return error.MissingFixtureNeedle;
    canonical[second_hunk + "\"old_start\":".len] = '1';
    const second_new = std.mem.indexOfPos(u8, canonical, second_hunk, "\"new_start\":20") orelse return error.MissingFixtureNeedle;
    canonical[second_new + "\"new_start\":".len] = '1';
    var search_index = second_new;
    while (std.mem.indexOfPos(u8, canonical, search_index, "\"line\":20")) |line_index| {
        canonical[line_index + "\"line\":".len] = '1';
        search_index = line_index + "\"line\":20".len;
    }
    try std.testing.expectError(error.InvalidValue, protocol.ReviewUnit.parseStrict(allocator, canonical));

    hunks[1].old_start = 10;
    hunks[1].new_start = 10;
    locations[1].line = 10;
    locations[3].line = 10;
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    hunks[0] = .{ .old_start = 10, .old_count = 2, .new_start = 10, .new_count = 2, .lines = &lines };
    hunks[1] = .{ .old_start = 11, .old_count = 1, .new_start = 11, .new_count = 1, .lines = lines[1..2] };
    locations[1].line = 11;
    locations[3].line = 11;
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    const added_lines = [_]protocol.DiffLine{
        .{ .kind = .added, .text = "one", .line_ending = .lf, .after_location = .{ .side = .after, .ordinal = 1 } },
        .{ .kind = .added, .text = "two", .line_ending = .none, .after_location = .{ .side = .after, .ordinal = 2 } },
    };
    const added_hunks = [_]protocol.ReviewHunk{
        .{ .old_start = 1, .old_count = 0, .new_start = 2, .new_count = 1, .lines = added_lines[0..1] },
        .{ .old_start = 3, .old_count = 0, .new_start = 5, .new_count = 1, .lines = added_lines[1..2] },
    };
    const added_locations = [_]protocol.ReviewLocation{
        .{ .location_id = .{ .side = .after, .ordinal = 1 }, .path_bytes = path, .side = .after, .line = 2 },
        .{ .location_id = .{ .side = .after, .ordinal = 2 }, .path_bytes = path, .side = .after, .line = 5 },
    };
    unit = testUnit();
    unit.hunks = &added_hunks;
    unit.locations = &added_locations;
    try std.testing.expect((try expectUnitRoundTrip(allocator, &unit)) <= limits.max_unit_bytes);

    var continued_after_none = added_lines;
    continued_after_none[0].line_ending = .none;
    continued_after_none[1].line_ending = .lf;
    const invalid_ending_hunk = [_]protocol.ReviewHunk{.{
        .old_start = 1,
        .old_count = 0,
        .new_start = 2,
        .new_count = 2,
        .lines = &continued_after_none,
    }};
    unit.hunks = &invalid_ending_hunk;
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    const removed_lines = [_]protocol.DiffLine{
        .{ .kind = .removed, .text = "one", .line_ending = .lf, .before_location = .{ .side = .before, .ordinal = 1 } },
        .{ .kind = .removed, .text = "two", .line_ending = .none, .before_location = .{ .side = .before, .ordinal = 2 } },
    };
    const removed_hunks = [_]protocol.ReviewHunk{
        .{ .old_start = 2, .old_count = 1, .new_start = 1, .new_count = 0, .lines = removed_lines[0..1] },
        .{ .old_start = 5, .old_count = 1, .new_start = 4, .new_count = 0, .lines = removed_lines[1..2] },
    };
    const removed_locations = [_]protocol.ReviewLocation{
        .{ .location_id = .{ .side = .before, .ordinal = 1 }, .path_bytes = path, .side = .before, .line = 2 },
        .{ .location_id = .{ .side = .before, .ordinal = 2 }, .path_bytes = path, .side = .before, .line = 5 },
    };
    unit = testUnit();
    unit.hunks = &removed_hunks;
    unit.locations = &removed_locations;
    try std.testing.expect((try expectUnitRoundTrip(allocator, &unit)) <= limits.max_unit_bytes);
}

test "AI review protocol unit mapping and raw coverage fail closed" {
    const allocator = std.testing.allocator;
    var unit = testUnit();
    var coverage = fixture_coverage;
    coverage[0].end_exclusive = limits.max_unit_raw_fragment_bytes;
    unit.coverage_spans = &coverage;
    _ = try expectUnitRoundTrip(allocator, &unit);
    coverage[0].end_exclusive += 1;
    try std.testing.expectError(error.LimitExceeded, unit.writeCanonical(allocator));

    coverage[0] = .{
        .start = limits.max_projection_bytes - 1,
        .end_exclusive = limits.max_projection_bytes,
    };
    unit.coverage_spans = &coverage;
    _ = try expectUnitRoundTrip(allocator, &unit);
    coverage[0].end_exclusive += 1;
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    const overlapping_coverage = [_]protocol.CoverageSpan{
        .{ .start = 0, .end_exclusive = 2 },
        .{ .start = 1, .end_exclusive = 3 },
    };
    unit = testUnit();
    unit.coverage_spans = &overlapping_coverage;
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    unit = testUnit();
    var locations = fixture_locations;
    locations[3].line = 3;
    unit.locations = &locations;
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    unit = testUnit();
    unit.old_path_bytes = "/absolute";
    unit.new_path_bytes = "/absolute";
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));
    unit.old_path_bytes = "dir/../escape";
    unit.new_path_bytes = "dir/../escape";
    try std.testing.expectError(error.InvalidValue, unit.writeCanonical(allocator));

    unit = testUnit();
    var cross_side = fixture_findings[0];
    cross_side.end_location.side = .before;
    var payload: protocol.FindingCandidatePayload = .{ .findings = &.{cross_side} };
    try std.testing.expectError(error.InvalidValue, payload.writeCanonical(allocator));

    var descending = fixture_findings[0];
    descending.start_location.ordinal = 3;
    descending.end_location.ordinal = 2;
    payload.findings = &.{descending};
    try std.testing.expectError(error.InvalidValue, payload.writeCanonical(allocator));

    var invalid_location = fixture_findings[0];
    invalid_location.start_location.ordinal = 0;
    payload.findings = &.{invalid_location};
    try std.testing.expectError(error.InvalidValue, payload.writeCanonical(allocator));
    invalid_location.start_location.ordinal = limits.max_locations_per_side + 1;
    try std.testing.expectError(error.InvalidValue, payload.writeCanonical(allocator));

    var batch: protocol.FindingCandidateBatch = .{
        .schema_version = 1,
        .plan_digest = identity.Sha256Digest.hash("plan"),
        .unit_id = .{ .ordinal = 0 },
        .status = .reviewed,
        .findings = &.{},
    };
    try std.testing.expectError(error.InvalidValue, batch.writeCanonical(allocator));
    batch.unit_id.ordinal = limits.max_review_units + 1;
    try std.testing.expectError(error.InvalidValue, batch.writeCanonical(allocator));
}

test "AI review protocol capability framing and compatibility are exact" {
    const allocator = std.testing.allocator;
    const bytes = try readProtocolFixture(allocator, "capabilities.json", limits.max_capabilities_bytes);
    defer allocator.free(bytes);
    var parsed = try protocol.CapabilityResponse.parseStrict(allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectError(
        error.IncompatibleCapabilities,
        protocol.requireCapabilities(&parsed.value, &.{.{ .name = "committed-review.target", .version = 1 }}),
    );
    try protocol.requireCapabilities(&parsed.value, &.{.{ .name = "committed-review.target", .version = 2 }});
    try std.testing.expectError(error.InvalidJson, protocol.CapabilityResponse.parseStrict(allocator, bytes[0 .. bytes.len - 1]));

    const extra_lf = try std.mem.concat(allocator, u8, &.{ bytes, "\n" });
    defer allocator.free(extra_lf);
    try std.testing.expectError(error.InvalidJson, protocol.CapabilityResponse.parseStrict(allocator, extra_lf));
    try std.testing.expectError(
        error.UnknownField,
        protocol.CapabilityResponse.parseStrict(
            allocator,
            "{\"schema_version\":1,\"status\":\"ok\",\"gitframe_version\":\"0.0.0\",\"diagnostic\":true,\"capabilities\":[]}\n",
        ),
    );

    const exact_versions = [_]u16{ 1, std.math.maxInt(u16) };
    var capabilities = [_]protocol.Capability{.{ .name = "capability", .versions = &exact_versions }};
    var response: protocol.CapabilityResponse = .{
        .schema_version = 1,
        .status = .ok,
        .gitframe_version = "1.0.0",
        .capabilities = &capabilities,
    };
    _ = try expectCapabilitiesRoundTrip(allocator, &response);

    const zero_version = [_]u16{0};
    capabilities[0].versions = &zero_version;
    try std.testing.expectError(error.InvalidValue, response.writeCanonical(allocator));
    const descending_versions = [_]u16{ 2, 1 };
    capabilities[0].versions = &descending_versions;
    try std.testing.expectError(error.InvalidValue, response.writeCanonical(allocator));
    capabilities[0].versions = &.{};
    try std.testing.expectError(error.MissingField, response.writeCanonical(allocator));

    const one_version = [_]u16{1};
    var unordered = [_]protocol.Capability{
        .{ .name = "same", .versions = &one_version },
        .{ .name = "same", .versions = &one_version },
    };
    response.capabilities = &unordered;
    try std.testing.expectError(error.InvalidValue, response.writeCanonical(allocator));
    unordered[0].name = "z";
    unordered[1].name = "a";
    try std.testing.expectError(error.InvalidValue, response.writeCanonical(allocator));
}
