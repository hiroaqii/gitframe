const std = @import("std");
const anchor_mod = @import("anchor.zig");
const artifact = @import("artifact.zig");
const identity = @import("identity.zig");
const limits = @import("limits.zig");
const strict = @import("strict_json.zig");
const target_mod = @import("target.zig");

pub const ParseError = strict.ParseError;

pub fn Parsed(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub fn parseFindingSet(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Parsed(artifact.FindingSet) {
    return parseArtifact(artifact.FindingSet, allocator, bytes, limits.max_artifact_bytes, parseFindingSetValue);
}

pub fn parseManifest(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Parsed(artifact.ReviewRunManifest) {
    return parseArtifact(artifact.ReviewRunManifest, allocator, bytes, limits.max_manifest_bytes, parseManifestValue);
}

pub fn parseDraft(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Parsed(artifact.ReviewDraftState) {
    return parseArtifact(artifact.ReviewDraftState, allocator, bytes, limits.max_artifact_bytes, parseDraftValue);
}

pub fn parseResult(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Parsed(artifact.RevisionReviewResult) {
    return parseArtifact(artifact.RevisionReviewResult, allocator, bytes, limits.max_artifact_bytes, parseResultValue);
}

fn parseArtifact(
    comptime T: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    maximum: usize,
    comptime parseValue: fn (*strict.Parser) ParseError!T,
) ParseError!Parsed(T) {
    if (bytes.len == 0 or bytes.len > maximum) return error.ArtifactTooLarge;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parser = strict.Parser.init(arena.allocator(), bytes);
    defer parser.deinit();
    const value = try parseValue(&parser);
    try parser.endDocument();
    return .{ .arena = arena, .value = value };
}

fn parseFindingSetValue(parser: *strict.Parser) ParseError!artifact.FindingSet {
    try parser.beginObject();
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var review_id: ?identity.ReviewId = null;
    var target: ?target_mod.CommittedReviewTarget = null;
    var producer: ?artifact.Producer = null;
    var findings: ?[]const artifact.Finding = null;

    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            try strict.markSeen(&seen, 0);
            schema_version = try parser.unsigned(u64);
        } else if (std.mem.eql(u8, key, "review_id")) {
            try strict.markSeen(&seen, 1);
            review_id = identity.ReviewId.parse(try parser.string()) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "target")) {
            try strict.markSeen(&seen, 2);
            target = try parseTarget(parser);
        } else if (std.mem.eql(u8, key, "producer")) {
            try strict.markSeen(&seen, 3);
            producer = try parseProducer(parser);
        } else if (std.mem.eql(u8, key, "findings")) {
            try strict.markSeen(&seen, 4);
            findings = try parseFindings(parser);
        } else {
            return error.UnknownField;
        }
    }
    try strict.requireFields(seen, 0b1_1111);
    try strict.validateSchemaVersion(schema_version.?);
    return .{
        .schema_version = schema_version.?,
        .review_id = review_id.?,
        .target = target.?,
        .producer = producer.?,
        .findings = findings.?,
    };
}

fn parseManifestValue(parser: *strict.Parser) ParseError!artifact.ReviewRunManifest {
    try parser.beginObject();
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var review_id: ?identity.ReviewId = null;
    var repository_id: ?identity.ReviewRepositoryId = null;
    var target: ?target_mod.CommittedReviewTarget = null;
    var created_at: ?[]const u8 = null;
    var display: ?artifact.DisplayMetadata = null;
    var finding_count: ?u32 = null;
    var producer: ?artifact.Producer = null;
    var digest: ?identity.Sha256Digest = null;

    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            try strict.markSeen(&seen, 0);
            schema_version = try parser.unsigned(u64);
        } else if (std.mem.eql(u8, key, "review_id")) {
            try strict.markSeen(&seen, 1);
            review_id = identity.ReviewId.parse(try parser.string()) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "review_repository_id")) {
            try strict.markSeen(&seen, 2);
            repository_id = identity.ReviewRepositoryId.parse(try parser.string()) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "target")) {
            try strict.markSeen(&seen, 3);
            target = try parseTarget(parser);
        } else if (std.mem.eql(u8, key, "created_at")) {
            try strict.markSeen(&seen, 4);
            const value = try parser.string();
            try strict.validateTimestamp(value);
            created_at = value;
        } else if (std.mem.eql(u8, key, "display")) {
            try strict.markSeen(&seen, 5);
            display = try parseDisplay(parser);
        } else if (std.mem.eql(u8, key, "finding_count")) {
            try strict.markSeen(&seen, 6);
            const value = try parser.unsigned(u32);
            if (value > limits.max_findings) return error.LimitExceeded;
            finding_count = value;
        } else if (std.mem.eql(u8, key, "producer")) {
            try strict.markSeen(&seen, 7);
            producer = try parseProducer(parser);
        } else if (std.mem.eql(u8, key, "findings_digest")) {
            try strict.markSeen(&seen, 8);
            digest = identity.Sha256Digest.parse(try parser.string()) catch return error.InvalidValue;
        } else {
            return error.UnknownField;
        }
    }
    const required = (@as(u32, 1) << 0) | (@as(u32, 1) << 1) | (@as(u32, 1) << 2) |
        (@as(u32, 1) << 3) | (@as(u32, 1) << 4) | (@as(u32, 1) << 6) |
        (@as(u32, 1) << 7) | (@as(u32, 1) << 8);
    try strict.requireFields(seen, required);
    try strict.validateSchemaVersion(schema_version.?);
    return .{
        .schema_version = schema_version.?,
        .review_id = review_id.?,
        .review_repository_id = repository_id.?,
        .target = target.?,
        .created_at = created_at.?,
        .display = display,
        .finding_count = finding_count.?,
        .producer = producer.?,
        .findings_digest = digest.?,
    };
}

fn parseDraftValue(parser: *strict.Parser) ParseError!artifact.ReviewDraftState {
    try parser.beginObject();
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var review_id: ?identity.ReviewId = null;
    var target: ?target_mod.CommittedReviewTarget = null;
    var digest: ?identity.Sha256Digest = null;
    var revision: ?u64 = null;
    var summary: ?[]const u8 = null;
    var dispositions: ?[]const artifact.FindingDisposition = null;

    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            try strict.markSeen(&seen, 0);
            schema_version = try parser.unsigned(u64);
        } else if (std.mem.eql(u8, key, "review_id")) {
            try strict.markSeen(&seen, 1);
            review_id = identity.ReviewId.parse(try parser.string()) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "target")) {
            try strict.markSeen(&seen, 2);
            target = try parseTarget(parser);
        } else if (std.mem.eql(u8, key, "findings_digest")) {
            try strict.markSeen(&seen, 3);
            digest = identity.Sha256Digest.parse(try parser.string()) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "revision")) {
            try strict.markSeen(&seen, 4);
            const value = try parser.unsigned(u64);
            if (value == 0) return error.InvalidValue;
            revision = value;
        } else if (std.mem.eql(u8, key, "summary")) {
            try strict.markSeen(&seen, 5);
            const value = try parser.string();
            try strict.validateText(value, limits.max_body_bytes, true);
            summary = value;
        } else if (std.mem.eql(u8, key, "finding_dispositions")) {
            try strict.markSeen(&seen, 6);
            dispositions = try parseDispositions(parser);
        } else {
            return error.UnknownField;
        }
    }
    const required = (@as(u32, 1) << 0) | (@as(u32, 1) << 1) | (@as(u32, 1) << 2) |
        (@as(u32, 1) << 3) | (@as(u32, 1) << 4) | (@as(u32, 1) << 6);
    try strict.requireFields(seen, required);
    try strict.validateSchemaVersion(schema_version.?);
    return .{
        .schema_version = schema_version.?,
        .review_id = review_id.?,
        .target = target.?,
        .findings_digest = digest.?,
        .revision = revision.?,
        .summary = summary,
        .finding_dispositions = dispositions.?,
    };
}

fn parseResultValue(parser: *strict.Parser) ParseError!artifact.RevisionReviewResult {
    try parser.beginObject();
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var review_id: ?identity.ReviewId = null;
    var target: ?target_mod.CommittedReviewTarget = null;
    var digest: ?identity.Sha256Digest = null;
    var result_value: ?artifact.ReviewResultValue = null;
    var summary: ?[]const u8 = null;
    var dispositions: ?[]const artifact.FindingDisposition = null;
    var notes: ?[]const artifact.AnchoredNote = null;

    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            try strict.markSeen(&seen, 0);
            schema_version = try parser.unsigned(u64);
        } else if (std.mem.eql(u8, key, "review_id")) {
            try strict.markSeen(&seen, 1);
            review_id = identity.ReviewId.parse(try parser.string()) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "target")) {
            try strict.markSeen(&seen, 2);
            target = try parseTarget(parser);
        } else if (std.mem.eql(u8, key, "findings_digest")) {
            try strict.markSeen(&seen, 3);
            digest = identity.Sha256Digest.parse(try parser.string()) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "result")) {
            try strict.markSeen(&seen, 4);
            result_value = try parseResultEnum(try parser.string());
        } else if (std.mem.eql(u8, key, "summary")) {
            try strict.markSeen(&seen, 5);
            const value = try parser.string();
            try strict.validateText(value, limits.max_body_bytes, true);
            summary = value;
        } else if (std.mem.eql(u8, key, "finding_dispositions")) {
            try strict.markSeen(&seen, 6);
            dispositions = try parseDispositions(parser);
        } else if (std.mem.eql(u8, key, "anchored_notes")) {
            try strict.markSeen(&seen, 7);
            notes = try parseAnchoredNotes(parser);
        } else {
            return error.UnknownField;
        }
    }
    const required = (@as(u32, 1) << 0) | (@as(u32, 1) << 1) | (@as(u32, 1) << 2) |
        (@as(u32, 1) << 3) | (@as(u32, 1) << 4) | (@as(u32, 1) << 6) |
        (@as(u32, 1) << 7);
    try strict.requireFields(seen, required);
    try strict.validateSchemaVersion(schema_version.?);
    return .{
        .schema_version = schema_version.?,
        .review_id = review_id.?,
        .target = target.?,
        .findings_digest = digest.?,
        .result = result_value.?,
        .summary = summary,
        .finding_dispositions = dispositions.?,
        .anchored_notes = notes.?,
    };
}

fn parseTarget(parser: *strict.Parser) ParseError!target_mod.CommittedReviewTarget {
    try parser.beginObject();
    var seen: u32 = 0;
    var object_format: ?target_mod.ObjectFormat = null;
    var source_kind: ?target_mod.SourceKind = null;
    var base_oid_text: ?[]const u8 = null;
    var head_oid_text: ?[]const u8 = null;
    var diff_base_oid_text: ?[]const u8 = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "object_format")) {
            try strict.markSeen(&seen, 0);
            object_format = try parseObjectFormat(try parser.string());
        } else if (std.mem.eql(u8, key, "source_kind")) {
            try strict.markSeen(&seen, 1);
            source_kind = try parseSourceKind(try parser.string());
        } else if (std.mem.eql(u8, key, "base_oid")) {
            try strict.markSeen(&seen, 2);
            base_oid_text = try parser.string();
        } else if (std.mem.eql(u8, key, "head_oid")) {
            try strict.markSeen(&seen, 3);
            head_oid_text = try parser.string();
        } else if (std.mem.eql(u8, key, "diff_base_oid")) {
            try strict.markSeen(&seen, 4);
            diff_base_oid_text = try parser.string();
        } else {
            return error.UnknownField;
        }
    }
    try strict.requireFields(seen, 0b1_1111);
    const format = object_format.?;
    return .{
        .object_format = format,
        .source_kind = source_kind.?,
        .base_oid = target_mod.ObjectId.parse(format, base_oid_text.?) catch return error.InvalidValue,
        .head_oid = target_mod.ObjectId.parse(format, head_oid_text.?) catch return error.InvalidValue,
        .diff_base_oid = target_mod.ObjectId.parse(format, diff_base_oid_text.?) catch return error.InvalidValue,
    };
}

fn parseProducer(parser: *strict.Parser) ParseError!artifact.Producer {
    try parser.beginObject();
    var seen: u32 = 0;
    var name: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var skill_version: ?[]const u8 = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "name")) {
            try strict.markSeen(&seen, 0);
            const value = try parser.string();
            try strict.validateText(value, limits.max_short_text_bytes, false);
            name = value;
        } else if (std.mem.eql(u8, key, "model")) {
            try strict.markSeen(&seen, 1);
            const value = try parser.string();
            try strict.validateText(value, limits.max_short_text_bytes, false);
            model = value;
        } else if (std.mem.eql(u8, key, "version")) {
            try strict.markSeen(&seen, 2);
            const value = try parser.string();
            try strict.validateText(value, limits.max_short_text_bytes, false);
            version = value;
        } else if (std.mem.eql(u8, key, "skill_version")) {
            try strict.markSeen(&seen, 3);
            const value = try parser.string();
            try strict.validateText(value, limits.max_short_text_bytes, false);
            skill_version = value;
        } else {
            return error.UnknownField;
        }
    }
    try strict.requireFields(seen, 1);
    return .{ .name = name.?, .model = model, .version = version, .skill_version = skill_version };
}

fn parseDisplay(parser: *strict.Parser) ParseError!artifact.DisplayMetadata {
    try parser.beginObject();
    var seen: u32 = 0;
    var base_label: ?[]const u8 = null;
    var head_label: ?[]const u8 = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "base_label")) {
            try strict.markSeen(&seen, 0);
            const value = try parser.string();
            try strict.validateText(value, limits.max_short_text_bytes, false);
            base_label = value;
        } else if (std.mem.eql(u8, key, "head_label")) {
            try strict.markSeen(&seen, 1);
            const value = try parser.string();
            try strict.validateText(value, limits.max_short_text_bytes, false);
            head_label = value;
        } else {
            return error.UnknownField;
        }
    }
    if (seen == 0) return error.MissingField;
    return .{ .base_label = base_label, .head_label = head_label };
}

fn parseFindings(parser: *strict.Parser) ParseError![]const artifact.Finding {
    try parser.beginArray();
    var list = std.array_list.Managed(artifact.Finding).init(parser.allocator);
    while (try parser.nextArrayObject()) {
        if (list.items.len == limits.max_findings) return error.LimitExceeded;
        const finding = try parseFindingObject(parser);
        for (list.items) |existing| {
            if (existing.finding_id.eql(finding.finding_id)) return error.DuplicateFindingId;
        }
        try list.append(finding);
    }
    return try list.toOwnedSlice();
}

fn parseFindingObject(parser: *strict.Parser) ParseError!artifact.Finding {
    var seen: u32 = 0;
    var finding_id: ?artifact.FindingId = null;
    var anchor: ?anchor_mod.CodeAnchor = null;
    var severity: ?artifact.Severity = null;
    var title: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    var suggestion: ?[]const u8 = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "finding_id")) {
            try strict.markSeen(&seen, 0);
            const value = try parser.string();
            try strict.validateFindingId(value);
            finding_id = .{ .bytes = value };
        } else if (std.mem.eql(u8, key, "anchor")) {
            try strict.markSeen(&seen, 1);
            anchor = try parseAnchor(parser);
        } else if (std.mem.eql(u8, key, "severity")) {
            try strict.markSeen(&seen, 2);
            severity = try parseSeverity(try parser.string());
        } else if (std.mem.eql(u8, key, "title")) {
            try strict.markSeen(&seen, 3);
            const value = try parser.string();
            try strict.validateText(value, limits.max_short_text_bytes, false);
            title = value;
        } else if (std.mem.eql(u8, key, "body")) {
            try strict.markSeen(&seen, 4);
            const value = try parser.string();
            try strict.validateText(value, limits.max_body_bytes, true);
            body = value;
        } else if (std.mem.eql(u8, key, "suggestion")) {
            try strict.markSeen(&seen, 5);
            const value = try parser.string();
            try strict.validateText(value, limits.max_body_bytes, true);
            suggestion = value;
        } else {
            return error.UnknownField;
        }
    }
    try strict.requireFields(seen, 0b1_1111);
    return .{
        .finding_id = finding_id.?,
        .anchor = anchor.?,
        .severity = severity.?,
        .title = title.?,
        .body = body.?,
        .suggestion = suggestion,
    };
}

fn parseAnchor(parser: *strict.Parser) ParseError!anchor_mod.CodeAnchor {
    try parser.beginObject();
    var seen: u32 = 0;
    var encoded_path: ?[]const u8 = null;
    var display_path: ?[]const u8 = null;
    var side: ?anchor_mod.AnchorSide = null;
    var start_line: ?u32 = null;
    var end_line: ?u32 = null;
    var digest: ?identity.Sha256Digest = null;
    var quoted_text: ?[]const u8 = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "path_bytes_b64")) {
            try strict.markSeen(&seen, 0);
            encoded_path = try parser.string();
        } else if (std.mem.eql(u8, key, "display_path")) {
            try strict.markSeen(&seen, 1);
            const value = try parser.string();
            try strict.validateText(value, limits.max_display_path_bytes, false);
            display_path = value;
        } else if (std.mem.eql(u8, key, "side")) {
            try strict.markSeen(&seen, 2);
            side = try parseAnchorSide(try parser.string());
        } else if (std.mem.eql(u8, key, "start_line")) {
            try strict.markSeen(&seen, 3);
            const value = try parser.unsigned(u32);
            if (value == 0) return error.InvalidValue;
            start_line = value;
        } else if (std.mem.eql(u8, key, "end_line")) {
            try strict.markSeen(&seen, 4);
            const value = try parser.unsigned(u32);
            if (value == 0) return error.InvalidValue;
            end_line = value;
        } else if (std.mem.eql(u8, key, "content_digest")) {
            try strict.markSeen(&seen, 5);
            digest = identity.Sha256Digest.parse(try parser.string()) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "quoted_text")) {
            try strict.markSeen(&seen, 6);
            const value = try parser.string();
            try strict.validateText(value, limits.max_body_bytes, true);
            quoted_text = value;
        } else {
            return error.UnknownField;
        }
    }
    const required = (@as(u32, 1) << 0) | (@as(u32, 1) << 2) | (@as(u32, 1) << 3) |
        (@as(u32, 1) << 4) | (@as(u32, 1) << 5);
    try strict.requireFields(seen, required);
    if (start_line.? > end_line.?) return error.InvalidValue;
    return .{
        .path_bytes = try strict.decodeRawPath(parser.allocator, encoded_path.?),
        .display_path = display_path,
        .side = side.?,
        .start_line = start_line.?,
        .end_line = end_line.?,
        .content_digest = digest.?,
        .quoted_text = quoted_text,
    };
}

fn parseDispositions(parser: *strict.Parser) ParseError![]const artifact.FindingDisposition {
    try parser.beginArray();
    var list = std.array_list.Managed(artifact.FindingDisposition).init(parser.allocator);
    while (try parser.nextArrayObject()) {
        if (list.items.len == limits.max_dispositions) return error.LimitExceeded;
        const value = try parseDispositionObject(parser);
        for (list.items) |existing| {
            if (existing.finding_id.eql(value.finding_id)) return error.DuplicateDispositionId;
        }
        try list.append(value);
    }
    return try list.toOwnedSlice();
}

fn parseDispositionObject(parser: *strict.Parser) ParseError!artifact.FindingDisposition {
    var seen: u32 = 0;
    var finding_id: ?artifact.FindingId = null;
    var disposition: ?artifact.FindingDispositionValue = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "finding_id")) {
            try strict.markSeen(&seen, 0);
            const value = try parser.string();
            try strict.validateFindingId(value);
            finding_id = .{ .bytes = value };
        } else if (std.mem.eql(u8, key, "disposition")) {
            try strict.markSeen(&seen, 1);
            disposition = try parseDispositionEnum(try parser.string());
        } else {
            return error.UnknownField;
        }
    }
    try strict.requireFields(seen, 0b11);
    return .{ .finding_id = finding_id.?, .disposition = disposition.? };
}

fn parseAnchoredNotes(parser: *strict.Parser) ParseError![]const artifact.AnchoredNote {
    try parser.beginArray();
    var list = std.array_list.Managed(artifact.AnchoredNote).init(parser.allocator);
    while (try parser.nextArrayObject()) {
        if (list.items.len == limits.max_anchored_notes) return error.LimitExceeded;
        try list.append(try parseAnchoredNoteObject(parser));
    }
    return try list.toOwnedSlice();
}

fn parseAnchoredNoteObject(parser: *strict.Parser) ParseError!artifact.AnchoredNote {
    var seen: u32 = 0;
    var anchor: ?anchor_mod.CodeAnchor = null;
    var body: ?[]const u8 = null;
    var related_ids: ?[]const artifact.FindingId = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "anchor")) {
            try strict.markSeen(&seen, 0);
            anchor = try parseAnchor(parser);
        } else if (std.mem.eql(u8, key, "body")) {
            try strict.markSeen(&seen, 1);
            const value = try parser.string();
            try strict.validateText(value, limits.max_body_bytes, true);
            body = value;
        } else if (std.mem.eql(u8, key, "related_finding_ids")) {
            try strict.markSeen(&seen, 2);
            related_ids = try parseFindingIds(parser);
        } else {
            return error.UnknownField;
        }
    }
    try strict.requireFields(seen, 0b111);
    return .{ .anchor = anchor.?, .body = body.?, .related_finding_ids = related_ids.? };
}

fn parseFindingIds(parser: *strict.Parser) ParseError![]const artifact.FindingId {
    try parser.beginArray();
    var list = std.array_list.Managed(artifact.FindingId).init(parser.allocator);
    while (true) {
        const token = parser.stringOrArrayEnd() catch |err| return err;
        if (token == null) break;
        if (list.items.len == limits.max_related_finding_ids) return error.LimitExceeded;
        const id: artifact.FindingId = .{ .bytes = token.? };
        try strict.validateFindingId(id.bytes);
        for (list.items) |existing| {
            if (existing.eql(id)) return error.DuplicateRelatedFindingId;
        }
        try list.append(id);
    }
    return try list.toOwnedSlice();
}

fn parseObjectFormat(text: []const u8) ParseError!target_mod.ObjectFormat {
    if (std.mem.eql(u8, text, "sha1")) return .sha1;
    if (std.mem.eql(u8, text, "sha256")) return .sha256;
    return error.InvalidValue;
}

fn parseSourceKind(text: []const u8) ParseError!target_mod.SourceKind {
    if (std.mem.eql(u8, text, "branch_range")) return .branch_range;
    return error.InvalidValue;
}

fn parseAnchorSide(text: []const u8) ParseError!anchor_mod.AnchorSide {
    if (std.mem.eql(u8, text, "before")) return .before;
    if (std.mem.eql(u8, text, "after")) return .after;
    return error.InvalidValue;
}

fn parseSeverity(text: []const u8) ParseError!artifact.Severity {
    if (std.mem.eql(u8, text, "info")) return .info;
    if (std.mem.eql(u8, text, "warning")) return .warning;
    if (std.mem.eql(u8, text, "error")) return .@"error";
    return error.InvalidValue;
}

fn parseDispositionEnum(text: []const u8) ParseError!artifact.FindingDispositionValue {
    if (std.mem.eql(u8, text, "unreviewed")) return .unreviewed;
    if (std.mem.eql(u8, text, "accepted")) return .accepted;
    if (std.mem.eql(u8, text, "dismissed")) return .dismissed;
    return error.InvalidValue;
}

fn parseResultEnum(text: []const u8) ParseError!artifact.ReviewResultValue {
    if (std.mem.eql(u8, text, "approved")) return .approved;
    if (std.mem.eql(u8, text, "needs_changes")) return .needs_changes;
    if (std.mem.eql(u8, text, "canceled")) return .canceled;
    return error.InvalidValue;
}

pub const ValidationError = error{
    SchemaMismatch,
    ReviewIdMismatch,
    TargetMismatch,
    ProducerMismatch,
    FindingCountMismatch,
    FindingsDigestMismatch,
    DispositionCountMismatch,
    DuplicateDispositionId,
    UnknownFindingId,
    MissingFindingId,
    DuplicateRelatedFindingId,
    RelatedFindingIdNotFound,
    NeedsChangesEvidenceMissing,
};

pub fn validateManifestFindingSet(
    manifest: *const artifact.ReviewRunManifest,
    exact_findings_bytes: []const u8,
    finding_set: *const artifact.FindingSet,
) ValidationError!void {
    if (manifest.schema_version != limits.schema_version or finding_set.schema_version != limits.schema_version) {
        return error.SchemaMismatch;
    }
    if (!manifest.review_id.eql(finding_set.review_id)) return error.ReviewIdMismatch;
    if (!manifest.target.eql(&finding_set.target)) return error.TargetMismatch;
    if (!manifest.producer.eql(finding_set.producer)) return error.ProducerMismatch;
    if (manifest.finding_count != finding_set.findings.len) return error.FindingCountMismatch;
    if (!manifest.findings_digest.eql(identity.Sha256Digest.hash(exact_findings_bytes))) {
        return error.FindingsDigestMismatch;
    }
}

pub fn validateDraftAgainst(
    draft: *const artifact.ReviewDraftState,
    finding_set: *const artifact.FindingSet,
    findings_digest: identity.Sha256Digest,
) ValidationError!void {
    try validateArtifactBinding(
        draft.schema_version,
        draft.review_id,
        &draft.target,
        draft.findings_digest,
        finding_set,
        findings_digest,
    );
    try validateDispositionSnapshot(draft.finding_dispositions, finding_set);
}

pub fn validateResultAgainst(
    result: *const artifact.RevisionReviewResult,
    finding_set: *const artifact.FindingSet,
    findings_digest: identity.Sha256Digest,
) ValidationError!void {
    try validateArtifactBinding(
        result.schema_version,
        result.review_id,
        &result.target,
        result.findings_digest,
        finding_set,
        findings_digest,
    );
    try validateDispositionSnapshot(result.finding_dispositions, finding_set);
    for (result.anchored_notes) |note| {
        for (note.related_finding_ids, 0..) |related, index| {
            if (finding_set.findingIndex(related) == null) return error.RelatedFindingIdNotFound;
            for (note.related_finding_ids[0..index]) |prior| {
                if (prior.eql(related)) return error.DuplicateRelatedFindingId;
            }
        }
    }
    if (result.result == .needs_changes and
        result.summary == null and
        result.anchored_notes.len == 0 and
        !hasAcceptedFinding(result.finding_dispositions))
    {
        return error.NeedsChangesEvidenceMissing;
    }
}

fn validateArtifactBinding(
    schema_version: u64,
    review_id: identity.ReviewId,
    target: *const target_mod.CommittedReviewTarget,
    artifact_digest: identity.Sha256Digest,
    finding_set: *const artifact.FindingSet,
    findings_digest: identity.Sha256Digest,
) ValidationError!void {
    if (schema_version != limits.schema_version or finding_set.schema_version != limits.schema_version) {
        return error.SchemaMismatch;
    }
    if (!review_id.eql(finding_set.review_id)) return error.ReviewIdMismatch;
    if (!target.eql(&finding_set.target)) return error.TargetMismatch;
    if (!artifact_digest.eql(findings_digest)) return error.FindingsDigestMismatch;
}

fn validateDispositionSnapshot(
    dispositions: []const artifact.FindingDisposition,
    finding_set: *const artifact.FindingSet,
) ValidationError!void {
    if (dispositions.len != finding_set.findings.len) return error.DispositionCountMismatch;
    for (dispositions, 0..) |disposition, index| {
        if (finding_set.findingIndex(disposition.finding_id) == null) return error.UnknownFindingId;
        for (dispositions[0..index]) |prior| {
            if (prior.finding_id.eql(disposition.finding_id)) return error.DuplicateDispositionId;
        }
    }
    for (finding_set.findings) |finding| {
        var found = false;
        for (dispositions) |disposition| {
            if (finding.finding_id.eql(disposition.finding_id)) {
                found = true;
                break;
            }
        }
        if (!found) return error.MissingFindingId;
    }
}

fn hasAcceptedFinding(dispositions: []const artifact.FindingDisposition) bool {
    for (dispositions) |disposition| if (disposition.disposition == .accepted) return true;
    return false;
}

pub fn writeFindingSetAlloc(allocator: std.mem.Allocator, value: *const artifact.FindingSet) ParseError![]u8 {
    try validateFindingSetValue(value);
    const buffer = try allocator.alloc(u8, limits.max_artifact_bytes);
    errdefer allocator.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    writeFindingSet(&stringify, allocator, value) catch |err| switch (err) {
        error.WriteFailed => return error.ArtifactTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
    };
    writer.writeByte('\n') catch return error.ArtifactTooLarge;
    return try allocator.realloc(buffer, writer.buffered().len);
}

pub fn writeManifestAlloc(allocator: std.mem.Allocator, value: *const artifact.ReviewRunManifest) ParseError![]u8 {
    try validateManifestValue(value);
    const buffer = try allocator.alloc(u8, limits.max_manifest_bytes);
    errdefer allocator.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    writeManifest(&stringify, value) catch return error.ArtifactTooLarge;
    writer.writeByte('\n') catch return error.ArtifactTooLarge;
    return try allocator.realloc(buffer, writer.buffered().len);
}

pub fn writeDraftAlloc(allocator: std.mem.Allocator, value: *const artifact.ReviewDraftState) ParseError![]u8 {
    try validateDraftValue(value);
    const buffer = try allocator.alloc(u8, limits.max_artifact_bytes);
    errdefer allocator.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    writeDraft(&stringify, value) catch return error.ArtifactTooLarge;
    writer.writeByte('\n') catch return error.ArtifactTooLarge;
    return try allocator.realloc(buffer, writer.buffered().len);
}

pub fn writeResultAlloc(allocator: std.mem.Allocator, value: *const artifact.RevisionReviewResult) ParseError![]u8 {
    try validateResultValue(value);
    const buffer = try allocator.alloc(u8, limits.max_artifact_bytes);
    errdefer allocator.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    writeResult(&stringify, allocator, value) catch |err| switch (err) {
        error.WriteFailed => return error.ArtifactTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
    };
    writer.writeByte('\n') catch return error.ArtifactTooLarge;
    return try allocator.realloc(buffer, writer.buffered().len);
}

fn validateFindingSetValue(value: *const artifact.FindingSet) ParseError!void {
    try strict.validateSchemaVersion(value.schema_version);
    try validateReviewId(value.review_id);
    try validateTarget(&value.target);
    try validateProducer(value.producer);
    if (value.findings.len > limits.max_findings) return error.LimitExceeded;
    for (value.findings, 0..) |finding, index| {
        try validateFinding(finding);
        for (value.findings[0..index]) |prior| {
            if (prior.finding_id.eql(finding.finding_id)) return error.DuplicateFindingId;
        }
    }
}

fn validateManifestValue(value: *const artifact.ReviewRunManifest) ParseError!void {
    try strict.validateSchemaVersion(value.schema_version);
    try validateReviewId(value.review_id);
    try validateRepositoryId(value.review_repository_id);
    try validateTarget(&value.target);
    try strict.validateTimestamp(value.created_at);
    if (value.display) |display| {
        if (display.base_label == null and display.head_label == null) return error.MissingField;
        if (display.base_label) |text| try strict.validateText(text, limits.max_short_text_bytes, false);
        if (display.head_label) |text| try strict.validateText(text, limits.max_short_text_bytes, false);
    }
    if (value.finding_count > limits.max_findings) return error.LimitExceeded;
    try validateProducer(value.producer);
}

fn validateDraftValue(value: *const artifact.ReviewDraftState) ParseError!void {
    try strict.validateSchemaVersion(value.schema_version);
    try validateReviewId(value.review_id);
    try validateTarget(&value.target);
    if (value.revision == 0) return error.InvalidValue;
    if (value.summary) |summary| try strict.validateText(summary, limits.max_body_bytes, true);
    try validateDispositionsStandalone(value.finding_dispositions);
}

fn validateResultValue(value: *const artifact.RevisionReviewResult) ParseError!void {
    try strict.validateSchemaVersion(value.schema_version);
    try validateReviewId(value.review_id);
    try validateTarget(&value.target);
    if (value.summary) |summary| try strict.validateText(summary, limits.max_body_bytes, true);
    try validateDispositionsStandalone(value.finding_dispositions);
    if (value.anchored_notes.len > limits.max_anchored_notes) return error.LimitExceeded;
    for (value.anchored_notes) |note| {
        try validateAnchor(note.anchor);
        try strict.validateText(note.body, limits.max_body_bytes, true);
        if (note.related_finding_ids.len > limits.max_related_finding_ids) return error.LimitExceeded;
        for (note.related_finding_ids, 0..) |related, index| {
            try strict.validateFindingId(related.bytes);
            for (note.related_finding_ids[0..index]) |prior| {
                if (prior.eql(related)) return error.DuplicateRelatedFindingId;
            }
        }
    }
    if (value.result == .needs_changes and
        value.summary == null and value.anchored_notes.len == 0 and
        !hasAcceptedFinding(value.finding_dispositions))
    {
        return error.InvalidValue;
    }
}

fn validateReviewId(value: identity.ReviewId) ParseError!void {
    const text = value.canonical();
    _ = identity.ReviewId.parse(&text) catch return error.InvalidValue;
}

fn validateRepositoryId(value: identity.ReviewRepositoryId) ParseError!void {
    const text = value.canonical();
    _ = identity.ReviewRepositoryId.parse(&text) catch return error.InvalidValue;
}

fn validateTarget(value: *const target_mod.CommittedReviewTarget) ParseError!void {
    value.validate() catch return error.InvalidValue;
}

fn validateProducer(value: artifact.Producer) ParseError!void {
    try strict.validateText(value.name, limits.max_short_text_bytes, false);
    if (value.model) |text| try strict.validateText(text, limits.max_short_text_bytes, false);
    if (value.version) |text| try strict.validateText(text, limits.max_short_text_bytes, false);
    if (value.skill_version) |text| try strict.validateText(text, limits.max_short_text_bytes, false);
}

fn validateFinding(value: artifact.Finding) ParseError!void {
    try strict.validateFindingId(value.finding_id.bytes);
    try validateAnchor(value.anchor);
    try strict.validateText(value.title, limits.max_short_text_bytes, false);
    try strict.validateText(value.body, limits.max_body_bytes, true);
    if (value.suggestion) |text| try strict.validateText(text, limits.max_body_bytes, true);
}

fn validateAnchor(value: anchor_mod.CodeAnchor) ParseError!void {
    if (value.path_bytes.len == 0 or value.path_bytes.len > limits.max_raw_path_bytes or
        std.mem.indexOfScalar(u8, value.path_bytes, 0) != null)
    {
        return error.InvalidValue;
    }
    if (value.display_path) |text| try strict.validateText(text, limits.max_display_path_bytes, false);
    if (value.start_line == 0 or value.end_line < value.start_line) return error.InvalidValue;
    if (value.quoted_text) |text| try strict.validateText(text, limits.max_body_bytes, true);
}

fn validateDispositionsStandalone(values: []const artifact.FindingDisposition) ParseError!void {
    if (values.len > limits.max_dispositions) return error.LimitExceeded;
    for (values, 0..) |value, index| {
        try strict.validateFindingId(value.finding_id.bytes);
        for (values[0..index]) |prior| {
            if (prior.finding_id.eql(value.finding_id)) return error.DuplicateDispositionId;
        }
    }
}

fn writeFindingSet(
    stringify: *std.json.Stringify,
    allocator: std.mem.Allocator,
    value: *const artifact.FindingSet,
) !void {
    try stringify.beginObject();
    try fieldUnsigned(stringify, "schema_version", value.schema_version);
    try fieldReviewId(stringify, "review_id", value.review_id);
    try stringify.objectField("target");
    try writeTarget(stringify, &value.target);
    try stringify.objectField("producer");
    try writeProducer(stringify, value.producer);
    try stringify.objectField("findings");
    try stringify.beginArray();
    for (value.findings) |finding| try writeFinding(stringify, allocator, finding);
    try stringify.endArray();
    try stringify.endObject();
}

fn writeManifest(stringify: *std.json.Stringify, value: *const artifact.ReviewRunManifest) !void {
    try stringify.beginObject();
    try fieldUnsigned(stringify, "schema_version", value.schema_version);
    try fieldReviewId(stringify, "review_id", value.review_id);
    try fieldRepositoryId(stringify, "review_repository_id", value.review_repository_id);
    try stringify.objectField("target");
    try writeTarget(stringify, &value.target);
    try fieldString(stringify, "created_at", value.created_at);
    if (value.display) |display| {
        try stringify.objectField("display");
        try stringify.beginObject();
        if (display.base_label) |text| try fieldString(stringify, "base_label", text);
        if (display.head_label) |text| try fieldString(stringify, "head_label", text);
        try stringify.endObject();
    }
    try fieldUnsigned(stringify, "finding_count", value.finding_count);
    try stringify.objectField("producer");
    try writeProducer(stringify, value.producer);
    try fieldDigest(stringify, "findings_digest", value.findings_digest);
    try stringify.endObject();
}

fn writeDraft(stringify: *std.json.Stringify, value: *const artifact.ReviewDraftState) !void {
    try stringify.beginObject();
    try fieldUnsigned(stringify, "schema_version", value.schema_version);
    try fieldReviewId(stringify, "review_id", value.review_id);
    try stringify.objectField("target");
    try writeTarget(stringify, &value.target);
    try fieldDigest(stringify, "findings_digest", value.findings_digest);
    try fieldUnsigned(stringify, "revision", value.revision);
    if (value.summary) |text| try fieldString(stringify, "summary", text);
    try stringify.objectField("finding_dispositions");
    try writeDispositions(stringify, value.finding_dispositions);
    try stringify.endObject();
}

fn writeResult(
    stringify: *std.json.Stringify,
    allocator: std.mem.Allocator,
    value: *const artifact.RevisionReviewResult,
) !void {
    try stringify.beginObject();
    try fieldUnsigned(stringify, "schema_version", value.schema_version);
    try fieldReviewId(stringify, "review_id", value.review_id);
    try stringify.objectField("target");
    try writeTarget(stringify, &value.target);
    try fieldDigest(stringify, "findings_digest", value.findings_digest);
    try fieldString(stringify, "result", resultName(value.result));
    if (value.summary) |text| try fieldString(stringify, "summary", text);
    try stringify.objectField("finding_dispositions");
    try writeDispositions(stringify, value.finding_dispositions);
    try stringify.objectField("anchored_notes");
    try stringify.beginArray();
    for (value.anchored_notes) |note| {
        try stringify.beginObject();
        try stringify.objectField("anchor");
        try writeAnchor(stringify, allocator, note.anchor);
        try fieldString(stringify, "body", note.body);
        try stringify.objectField("related_finding_ids");
        try stringify.beginArray();
        for (note.related_finding_ids) |related| try stringify.write(related.bytes);
        try stringify.endArray();
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.endObject();
}

fn writeTarget(stringify: *std.json.Stringify, value: *const target_mod.CommittedReviewTarget) !void {
    try stringify.beginObject();
    try fieldString(stringify, "object_format", objectFormatName(value.object_format));
    try fieldString(stringify, "source_kind", sourceKindName(value.source_kind));
    try fieldString(stringify, "base_oid", value.base_oid.slice());
    try fieldString(stringify, "head_oid", value.head_oid.slice());
    try fieldString(stringify, "diff_base_oid", value.diff_base_oid.slice());
    try stringify.endObject();
}

fn writeProducer(stringify: *std.json.Stringify, value: artifact.Producer) !void {
    try stringify.beginObject();
    try fieldString(stringify, "name", value.name);
    if (value.model) |text| try fieldString(stringify, "model", text);
    if (value.version) |text| try fieldString(stringify, "version", text);
    if (value.skill_version) |text| try fieldString(stringify, "skill_version", text);
    try stringify.endObject();
}

fn writeFinding(
    stringify: *std.json.Stringify,
    allocator: std.mem.Allocator,
    value: artifact.Finding,
) !void {
    try stringify.beginObject();
    try fieldString(stringify, "finding_id", value.finding_id.bytes);
    try stringify.objectField("anchor");
    try writeAnchor(stringify, allocator, value.anchor);
    try fieldString(stringify, "severity", severityName(value.severity));
    try fieldString(stringify, "title", value.title);
    try fieldString(stringify, "body", value.body);
    if (value.suggestion) |text| try fieldString(stringify, "suggestion", text);
    try stringify.endObject();
}

fn writeAnchor(
    stringify: *std.json.Stringify,
    allocator: std.mem.Allocator,
    value: anchor_mod.CodeAnchor,
) !void {
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(value.path_bytes.len);
    const encoded_buffer = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded_buffer);
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(encoded_buffer, value.path_bytes);

    try stringify.beginObject();
    try fieldString(stringify, "path_bytes_b64", encoded);
    if (value.display_path) |text| try fieldString(stringify, "display_path", text);
    try fieldString(stringify, "side", anchorSideName(value.side));
    try fieldUnsigned(stringify, "start_line", value.start_line);
    try fieldUnsigned(stringify, "end_line", value.end_line);
    try fieldDigest(stringify, "content_digest", value.content_digest);
    if (value.quoted_text) |text| try fieldString(stringify, "quoted_text", text);
    try stringify.endObject();
}

fn writeDispositions(
    stringify: *std.json.Stringify,
    values: []const artifact.FindingDisposition,
) !void {
    try stringify.beginArray();
    for (values) |value| {
        try stringify.beginObject();
        try fieldString(stringify, "finding_id", value.finding_id.bytes);
        try fieldString(stringify, "disposition", dispositionName(value.disposition));
        try stringify.endObject();
    }
    try stringify.endArray();
}

fn fieldString(stringify: *std.json.Stringify, name: []const u8, value: []const u8) !void {
    try stringify.objectField(name);
    try stringify.write(value);
}

fn fieldUnsigned(stringify: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try stringify.objectField(name);
    try stringify.write(value);
}

fn fieldReviewId(stringify: *std.json.Stringify, name: []const u8, value: identity.ReviewId) !void {
    const text = value.canonical();
    try fieldString(stringify, name, &text);
}

fn fieldRepositoryId(
    stringify: *std.json.Stringify,
    name: []const u8,
    value: identity.ReviewRepositoryId,
) !void {
    const text = value.canonical();
    try fieldString(stringify, name, &text);
}

fn fieldDigest(stringify: *std.json.Stringify, name: []const u8, value: identity.Sha256Digest) !void {
    const text = value.canonical();
    try fieldString(stringify, name, &text);
}

fn objectFormatName(value: target_mod.ObjectFormat) []const u8 {
    return switch (value) {
        .sha1 => "sha1",
        .sha256 => "sha256",
    };
}

fn sourceKindName(value: target_mod.SourceKind) []const u8 {
    return switch (value) {
        .branch_range => "branch_range",
    };
}

fn anchorSideName(value: anchor_mod.AnchorSide) []const u8 {
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

fn dispositionName(value: artifact.FindingDispositionValue) []const u8 {
    return switch (value) {
        .unreviewed => "unreviewed",
        .accepted => "accepted",
        .dismissed => "dismissed",
    };
}

fn resultName(value: artifact.ReviewResultValue) []const u8 {
    return switch (value) {
        .approved => "approved",
        .needs_changes => "needs_changes",
        .canceled => "canceled",
    };
}

fn testTarget() !target_mod.CommittedReviewTarget {
    return .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = try target_mod.ObjectId.parse(.sha1, "0000000000000000000000000000000000000000"),
        .head_oid = try target_mod.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111"),
        .diff_base_oid = try target_mod.ObjectId.parse(.sha1, "0000000000000000000000000000000000000000"),
    };
}

fn testFindingSet() !artifact.FindingSet {
    const findings = &[_]artifact.Finding{.{
        .finding_id = .{ .bytes = "F-1" },
        .anchor = .{
            .path_bytes = "src/main.zig",
            .display_path = "src/main.zig",
            .side = .after,
            .start_line = 2,
            .end_line = 2,
            .content_digest = .{ .bytes = [_]u8{0} ** 32 },
            .quoted_text = "line\n",
        },
        .severity = .warning,
        .title = "A finding",
        .body = "Evidence\nDetails",
        .suggestion = "Use the committed value.",
    }};
    return .{
        .schema_version = 1,
        .review_id = try identity.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000"),
        .target = try testTarget(),
        .producer = .{ .name = "codex", .model = "gpt-x" },
        .findings = findings,
    };
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
}

test "committed review v1 golden fixtures round trip and bind as exact bytes" {
    const allocator = std.testing.allocator;
    const findings_bytes = try readFixture(allocator, "testdata/committed-review-v1/finding-set/canonical.json");
    defer allocator.free(findings_bytes);
    const manifest_bytes = try readFixture(allocator, "testdata/committed-review-v1/manifest/canonical.json");
    defer allocator.free(manifest_bytes);
    const draft_bytes = try readFixture(allocator, "testdata/committed-review-v1/draft/canonical.json");
    defer allocator.free(draft_bytes);
    const result_bytes = try readFixture(allocator, "testdata/committed-review-v1/result/canonical.json");
    defer allocator.free(result_bytes);

    var findings = try artifact.FindingSet.parseStrict(allocator, findings_bytes);
    defer findings.deinit();
    const rewritten_findings = try findings.value.writeCanonical(allocator);
    defer allocator.free(rewritten_findings);
    try std.testing.expectEqualSlices(u8, findings_bytes, rewritten_findings);

    var manifest = try artifact.ReviewRunManifest.parseStrict(allocator, manifest_bytes);
    defer manifest.deinit();
    try manifest.value.validateFindingSet(findings_bytes, &findings.value);
    const rewritten_manifest = try manifest.value.writeCanonical(allocator);
    defer allocator.free(rewritten_manifest);
    try std.testing.expectEqualSlices(u8, manifest_bytes, rewritten_manifest);

    const digest = identity.Sha256Digest.hash(findings_bytes);
    var draft = try artifact.ReviewDraftState.parseStrict(allocator, draft_bytes);
    defer draft.deinit();
    try draft.value.validateAgainst(&findings.value, digest);
    const rewritten_draft = try draft.value.writeCanonical(allocator);
    defer allocator.free(rewritten_draft);
    try std.testing.expectEqualSlices(u8, draft_bytes, rewritten_draft);

    var result = try artifact.RevisionReviewResult.parseStrict(allocator, result_bytes);
    defer result.deinit();
    try result.value.validateAgainst(&findings.value, digest);
    const rewritten_result = try result.value.writeCanonical(allocator);
    defer allocator.free(rewritten_result);
    try std.testing.expectEqualSlices(u8, result_bytes, rewritten_result);
}

test "fixtures preserve separate Runs on one target and reject structural aliases" {
    const allocator = std.testing.allocator;
    const canonical_bytes = try readFixture(allocator, "testdata/committed-review-v1/finding-set/canonical.json");
    defer allocator.free(canonical_bytes);
    var canonical = try artifact.FindingSet.parseStrict(allocator, canonical_bytes);
    defer canonical.deinit();
    const zero_bytes = try readFixture(allocator, "testdata/committed-review-v1/finding-set/zero-different-run.json");
    defer allocator.free(zero_bytes);
    var zero = try artifact.FindingSet.parseStrict(allocator, zero_bytes);
    defer zero.deinit();
    try std.testing.expect(canonical.value.target.eql(&zero.value.target));
    try std.testing.expect(!canonical.value.review_id.eql(zero.value.review_id));
    try std.testing.expect(!canonical.value.producer.eql(zero.value.producer));
    try std.testing.expectEqual(@as(usize, 0), zero.value.findings.len);
    const rewritten_zero = try zero.value.writeCanonical(allocator);
    defer allocator.free(rewritten_zero);
    try std.testing.expectEqualSlices(u8, zero_bytes, rewritten_zero);

    const duplicate_bytes = try readFixture(allocator, "testdata/committed-review-v1/negative/duplicate-top-level.json");
    defer allocator.free(duplicate_bytes);
    try std.testing.expectError(error.DuplicateField, artifact.FindingSet.parseStrict(allocator, duplicate_bytes));
    const unknown_bytes = try readFixture(allocator, "testdata/committed-review-v1/negative/unknown-nested.json");
    defer allocator.free(unknown_bytes);
    try std.testing.expectError(error.UnknownField, artifact.FindingSet.parseStrict(allocator, unknown_bytes));
    const misplaced_quote = try readFixture(allocator, "testdata/committed-review-v1/negative/finding-level-quoted-text.json");
    defer allocator.free(misplaced_quote);
    try std.testing.expectError(error.UnknownField, artifact.FindingSet.parseStrict(allocator, misplaced_quote));

    const boundary_bytes = try readFixture(allocator, "testdata/committed-review-v1/boundary/finding-id-max.json");
    defer allocator.free(boundary_bytes);
    var boundary = try artifact.FindingSet.parseStrict(allocator, boundary_bytes);
    defer boundary.deinit();
    try std.testing.expectEqual(limits.max_finding_id_bytes, boundary.value.findings[0].finding_id.bytes.len);
    const rewritten_boundary = try boundary.value.writeCanonical(allocator);
    defer allocator.free(rewritten_boundary);
    try std.testing.expectEqualSlices(u8, boundary_bytes, rewritten_boundary);
}

test "FindingSet canonical writer and strict parser round trip exact raw path bytes" {
    const allocator = std.testing.allocator;
    const value = try testFindingSet();
    const encoded = try value.writeCanonical(allocator);
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.endsWith(u8, encoded, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"path_bytes_b64\":\"c3JjL21haW4uemln\"") != null);

    var parsed = try artifact.FindingSet.parseStrict(allocator, encoded);
    defer parsed.deinit();
    try std.testing.expect(value.review_id.eql(parsed.value.review_id));
    try std.testing.expect(value.target.eql(&parsed.value.target));
    try std.testing.expectEqualSlices(u8, value.findings[0].anchor.path_bytes, parsed.value.findings[0].anchor.path_bytes);

    const rewritten = try parsed.value.writeCanonical(allocator);
    defer allocator.free(rewritten);
    try std.testing.expectEqualSlices(u8, encoded, rewritten);
}

test "strict artifact parsing rejects unknown duplicate nullable and noncanonical fields" {
    const allocator = std.testing.allocator;
    const valid = try (try testFindingSet()).writeCanonical(allocator);
    defer allocator.free(valid);

    const duplicate =
        "{\"schema_version\":1,\"schema_version\":1,\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\"," ++
        "\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"0000000000000000000000000000000000000000\"," ++
        "\"head_oid\":\"1111111111111111111111111111111111111111\",\"diff_base_oid\":\"0000000000000000000000000000000000000000\"}," ++
        "\"producer\":{\"name\":\"codex\"},\"findings\":[]}";
    try std.testing.expectError(error.DuplicateField, artifact.FindingSet.parseStrict(allocator, duplicate));

    const unknown =
        "{\"schema_version\":1,\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\"," ++
        "\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"0000000000000000000000000000000000000000\"," ++
        "\"head_oid\":\"1111111111111111111111111111111111111111\",\"diff_base_oid\":\"0000000000000000000000000000000000000000\"}," ++
        "\"producer\":{\"name\":\"codex\"},\"findings\":[],\"capabilities\":[]}";
    try std.testing.expectError(error.UnknownField, artifact.FindingSet.parseStrict(allocator, unknown));

    const nullable =
        "{\"schema_version\":1,\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\"," ++
        "\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"0000000000000000000000000000000000000000\"," ++
        "\"head_oid\":\"1111111111111111111111111111111111111111\",\"diff_base_oid\":\"0000000000000000000000000000000000000000\"}," ++
        "\"producer\":{\"name\":\"codex\",\"model\":null},\"findings\":[]}";
    try std.testing.expectError(error.InvalidType, artifact.FindingSet.parseStrict(allocator, nullable));

    var uppercase = try allocator.dupe(u8, valid);
    defer allocator.free(uppercase);
    const oid_offset = std.mem.indexOf(u8, uppercase, "\"head_oid\":\"1111") orelse unreachable;
    uppercase[oid_offset + "\"head_oid\":\"".len] = 'A';
    try std.testing.expectError(error.InvalidValue, artifact.FindingSet.parseStrict(allocator, uppercase));
}

test "manifest draft and result bind one exact FindingSet without digest aliases" {
    const allocator = std.testing.allocator;
    const finding_set = try testFindingSet();
    const findings_bytes = try finding_set.writeCanonical(allocator);
    defer allocator.free(findings_bytes);
    const digest = identity.Sha256Digest.hash(findings_bytes);

    const manifest: artifact.ReviewRunManifest = .{
        .schema_version = 1,
        .review_id = finding_set.review_id,
        .review_repository_id = try identity.ReviewRepositoryId.parse("123e4567-e89b-42d3-b456-426614174000"),
        .target = finding_set.target,
        .created_at = "2026-08-19T05:00:00Z",
        .display = .{ .base_label = "main", .head_label = "feature" },
        .finding_count = 1,
        .producer = finding_set.producer,
        .findings_digest = digest,
    };
    try manifest.validateFindingSet(findings_bytes, &finding_set);
    const manifest_bytes = try manifest.writeCanonical(allocator);
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try artifact.ReviewRunManifest.parseStrict(allocator, manifest_bytes);
    defer parsed_manifest.deinit();
    try parsed_manifest.value.validateFindingSet(findings_bytes, &finding_set);

    const dispositions = &[_]artifact.FindingDisposition{.{
        .finding_id = .{ .bytes = "F-1" },
        .disposition = .accepted,
    }};
    const draft: artifact.ReviewDraftState = .{
        .schema_version = 1,
        .review_id = finding_set.review_id,
        .target = finding_set.target,
        .findings_digest = digest,
        .revision = 1,
        .summary = null,
        .finding_dispositions = dispositions,
    };
    try draft.validateAgainst(&finding_set, digest);
    const draft_bytes = try draft.writeCanonical(allocator);
    defer allocator.free(draft_bytes);
    var parsed_draft = try artifact.ReviewDraftState.parseStrict(allocator, draft_bytes);
    defer parsed_draft.deinit();
    try parsed_draft.value.validateAgainst(&finding_set, digest);

    const result: artifact.RevisionReviewResult = .{
        .schema_version = 1,
        .review_id = finding_set.review_id,
        .target = finding_set.target,
        .findings_digest = digest,
        .result = .needs_changes,
        .summary = null,
        .finding_dispositions = dispositions,
        .anchored_notes = &.{},
    };
    try result.validateAgainst(&finding_set, digest);
    const result_bytes = try result.writeCanonical(allocator);
    defer allocator.free(result_bytes);
    var parsed_result = try artifact.RevisionReviewResult.parseStrict(allocator, result_bytes);
    defer parsed_result.deinit();
    try parsed_result.value.validateAgainst(&finding_set, digest);

    var changed_manifest = manifest;
    changed_manifest.findings_digest = identity.Sha256Digest.hash(findings_bytes[0 .. findings_bytes.len - 1]);
    try std.testing.expectError(
        error.FindingsDigestMismatch,
        changed_manifest.validateFindingSet(findings_bytes, &finding_set),
    );
}

test "disposition and related Finding references are complete unique and Run local" {
    const finding_set = try testFindingSet();
    const digest = identity.Sha256Digest.hash("exact bytes\n");
    const duplicate = &[_]artifact.FindingDisposition{
        .{ .finding_id = .{ .bytes = "F-1" }, .disposition = .accepted },
        .{ .finding_id = .{ .bytes = "F-1" }, .disposition = .dismissed },
    };
    const draft: artifact.ReviewDraftState = .{
        .schema_version = 1,
        .review_id = finding_set.review_id,
        .target = finding_set.target,
        .findings_digest = digest,
        .revision = 1,
        .summary = null,
        .finding_dispositions = duplicate,
    };
    try std.testing.expectError(error.DispositionCountMismatch, draft.validateAgainst(&finding_set, digest));

    const one = &[_]artifact.FindingDisposition{.{
        .finding_id = .{ .bytes = "F-1" },
        .disposition = .unreviewed,
    }};
    const unknown_ids = &[_]artifact.FindingId{.{ .bytes = "outside" }};
    const notes = &[_]artifact.AnchoredNote{.{
        .anchor = finding_set.findings[0].anchor,
        .body = "Review note",
        .related_finding_ids = unknown_ids,
    }};
    const result: artifact.RevisionReviewResult = .{
        .schema_version = 1,
        .review_id = finding_set.review_id,
        .target = finding_set.target,
        .findings_digest = digest,
        .result = .needs_changes,
        .summary = null,
        .finding_dispositions = one,
        .anchored_notes = notes,
    };
    try std.testing.expectError(error.RelatedFindingIdNotFound, result.validateAgainst(&finding_set, digest));
}

test "zero Finding results are valid and needs_changes requires explicit evidence" {
    var finding_set = try testFindingSet();
    finding_set.findings = &.{};
    const digest = identity.Sha256Digest.hash("{}\n");
    const approved: artifact.RevisionReviewResult = .{
        .schema_version = 1,
        .review_id = finding_set.review_id,
        .target = finding_set.target,
        .findings_digest = digest,
        .result = .approved,
        .summary = null,
        .finding_dispositions = &.{},
        .anchored_notes = &.{},
    };
    try approved.validateAgainst(&finding_set, digest);
    var needs_changes = approved;
    needs_changes.result = .needs_changes;
    try std.testing.expectError(
        error.NeedsChangesEvidenceMissing,
        needs_changes.validateAgainst(&finding_set, digest),
    );
}

test "schema boundary accepts maximum Finding ID and rejects plus one" {
    const allocator = std.testing.allocator;
    var finding_set = try testFindingSet();
    const exact = "a" ** limits.max_finding_id_bytes;
    var finding = finding_set.findings[0];
    finding.finding_id = .{ .bytes = exact[0..] };
    var findings = [_]artifact.Finding{finding};
    finding_set.findings = &findings;
    const encoded = try finding_set.writeCanonical(allocator);
    defer allocator.free(encoded);
    var parsed = try artifact.FindingSet.parseStrict(allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, limits.max_finding_id_bytes), parsed.value.findings[0].finding_id.bytes.len);

    const plus_one = "a" ** (limits.max_finding_id_bytes + 1);
    findings[0].finding_id = .{ .bytes = plus_one[0..] };
    try std.testing.expectError(error.InvalidValue, finding_set.writeCanonical(allocator));
}

test "artifact byte caps accept exact valid documents and reject plus one" {
    const allocator = std.testing.allocator;
    const zero_fixture = try readFixture(allocator, "testdata/committed-review-v1/finding-set/zero-different-run.json");
    defer allocator.free(zero_fixture);
    const exact_artifact = try allocator.alloc(u8, limits.max_artifact_bytes);
    @memcpy(exact_artifact[0..zero_fixture.len], zero_fixture);
    @memset(exact_artifact[zero_fixture.len..], ' ');
    var parsed_exact = try artifact.FindingSet.parseStrict(allocator, exact_artifact);
    parsed_exact.deinit();
    allocator.free(exact_artifact);

    const oversized_artifact = try allocator.alloc(u8, limits.max_artifact_bytes + 1);
    defer allocator.free(oversized_artifact);
    @memcpy(oversized_artifact[0..zero_fixture.len], zero_fixture);
    @memset(oversized_artifact[zero_fixture.len..], ' ');
    try std.testing.expectError(error.ArtifactTooLarge, artifact.FindingSet.parseStrict(allocator, oversized_artifact));

    const manifest_fixture = try readFixture(allocator, "testdata/committed-review-v1/manifest/canonical.json");
    defer allocator.free(manifest_fixture);
    const exact_manifest = try allocator.alloc(u8, limits.max_manifest_bytes);
    @memcpy(exact_manifest[0..manifest_fixture.len], manifest_fixture);
    @memset(exact_manifest[manifest_fixture.len..], ' ');
    var parsed_manifest = try artifact.ReviewRunManifest.parseStrict(allocator, exact_manifest);
    parsed_manifest.deinit();
    allocator.free(exact_manifest);

    const oversized_manifest = try allocator.alloc(u8, limits.max_manifest_bytes + 1);
    defer allocator.free(oversized_manifest);
    @memcpy(oversized_manifest[0..manifest_fixture.len], manifest_fixture);
    @memset(oversized_manifest[manifest_fixture.len..], ' ');
    try std.testing.expectError(error.ArtifactTooLarge, artifact.ReviewRunManifest.parseStrict(allocator, oversized_manifest));
}

test "manifest digest binds one-byte whitespace and final-LF differences" {
    const allocator = std.testing.allocator;
    const findings_bytes = try readFixture(allocator, "testdata/committed-review-v1/finding-set/canonical.json");
    defer allocator.free(findings_bytes);
    const manifest_bytes = try readFixture(allocator, "testdata/committed-review-v1/manifest/canonical.json");
    defer allocator.free(manifest_bytes);
    var findings = try artifact.FindingSet.parseStrict(allocator, findings_bytes);
    defer findings.deinit();
    var manifest = try artifact.ReviewRunManifest.parseStrict(allocator, manifest_bytes);
    defer manifest.deinit();
    try manifest.value.validateFindingSet(findings_bytes, &findings.value);

    const changed = try allocator.dupe(u8, findings_bytes);
    defer allocator.free(changed);
    changed[changed.len - 2] = if (changed[changed.len - 2] == '}') ' ' else '}';
    try std.testing.expectError(
        error.FindingsDigestMismatch,
        manifest.value.validateFindingSet(changed, &findings.value),
    );

    const with_space = try std.mem.concat(allocator, u8, &.{ findings_bytes, " " });
    defer allocator.free(with_space);
    try std.testing.expectError(
        error.FindingsDigestMismatch,
        manifest.value.validateFindingSet(with_space, &findings.value),
    );
    try std.testing.expectError(
        error.FindingsDigestMismatch,
        manifest.value.validateFindingSet(findings_bytes[0 .. findings_bytes.len - 1], &findings.value),
    );

    var wrong_findings = findings.value;
    wrong_findings.review_id = try identity.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    try std.testing.expectError(error.ReviewIdMismatch, manifest.value.validateFindingSet(findings_bytes, &wrong_findings));
    wrong_findings = findings.value;
    wrong_findings.target.head_oid = try target_mod.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    try std.testing.expectError(error.TargetMismatch, manifest.value.validateFindingSet(findings_bytes, &wrong_findings));
    wrong_findings = findings.value;
    wrong_findings.producer.name = "another-producer";
    try std.testing.expectError(error.ProducerMismatch, manifest.value.validateFindingSet(findings_bytes, &wrong_findings));
    wrong_findings = findings.value;
    wrong_findings.findings = &.{};
    try std.testing.expectError(error.FindingCountMismatch, manifest.value.validateFindingSet(findings_bytes, &wrong_findings));
}

test "closed artifact enums reject every unlisted spelling" {
    try std.testing.expectEqual(target_mod.ObjectFormat.sha1, try parseObjectFormat("sha1"));
    try std.testing.expectEqual(target_mod.ObjectFormat.sha256, try parseObjectFormat("sha256"));
    try std.testing.expectError(error.InvalidValue, parseObjectFormat("SHA1"));
    try std.testing.expectError(error.InvalidValue, parseSourceKind("single_commit"));
    try std.testing.expectError(error.InvalidValue, parseAnchorSide("current"));
    try std.testing.expectError(error.InvalidValue, parseSeverity("critical"));
    try std.testing.expectError(error.InvalidValue, parseDispositionEnum("rejected"));
    try std.testing.expectError(error.InvalidValue, parseResultEnum("failed"));
}

test "strict artifact parse and canonical write release every failed allocation" {
    const input =
        "{\"schema_version\":1,\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\"," ++
        "\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\"," ++
        "\"base_oid\":\"0000000000000000000000000000000000000000\"," ++
        "\"head_oid\":\"1111111111111111111111111111111111111111\"," ++
        "\"diff_base_oid\":\"0000000000000000000000000000000000000000\"}," ++
        "\"producer\":{\"name\":\"codex\"},\"findings\":[]}";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn parse(allocator: std.mem.Allocator, bytes: []const u8) !void {
            var parsed = try artifact.FindingSet.parseStrict(allocator, bytes);
            defer parsed.deinit();
        }
    }.parse, .{input});

    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn write(allocator: std.mem.Allocator) !void {
            var value = try testFindingSet();
            value.findings = &.{};
            const bytes = try value.writeCanonical(allocator);
            defer allocator.free(bytes);
        }
    }.write, .{});
}

test "collection caps accept exact cardinality and reject plus one" {
    const allocator = std.testing.allocator;
    const count = limits.max_findings + 1;
    const id_storage = try allocator.alloc([16]u8, count);
    defer allocator.free(id_storage);
    const findings = try allocator.alloc(artifact.Finding, count);
    defer allocator.free(findings);
    const template = (try testFindingSet()).findings[0];
    for (findings, 0..) |*finding, index| {
        finding.* = template;
        finding.finding_id = .{ .bytes = try std.fmt.bufPrint(&id_storage[index], "F-{d}", .{index}) };
    }
    var finding_set = try testFindingSet();
    finding_set.findings = findings[0..limits.max_findings];
    const exact_findings = try finding_set.writeCanonical(allocator);
    allocator.free(exact_findings);
    const maximum_body = try allocator.alloc(u8, limits.max_body_bytes);
    defer allocator.free(maximum_body);
    @memset(maximum_body, 'x');
    for (findings[0..limits.max_findings]) |*finding| {
        finding.body = maximum_body;
        finding.suggestion = maximum_body;
    }
    try std.testing.expectError(error.ArtifactTooLarge, finding_set.writeCanonical(allocator));
    finding_set.findings = findings;
    try std.testing.expectError(error.LimitExceeded, finding_set.writeCanonical(allocator));

    const dispositions = try allocator.alloc(artifact.FindingDisposition, count);
    defer allocator.free(dispositions);
    for (dispositions, 0..) |*disposition, index| {
        disposition.* = .{ .finding_id = findings[index].finding_id, .disposition = .unreviewed };
    }
    var draft: artifact.ReviewDraftState = .{
        .schema_version = 1,
        .review_id = finding_set.review_id,
        .target = finding_set.target,
        .findings_digest = identity.Sha256Digest.hash("fixture"),
        .revision = 1,
        .summary = null,
        .finding_dispositions = dispositions[0..limits.max_dispositions],
    };
    const exact_draft = try draft.writeCanonical(allocator);
    allocator.free(exact_draft);
    draft.finding_dispositions = dispositions;
    try std.testing.expectError(error.LimitExceeded, draft.writeCanonical(allocator));

    const notes = try allocator.alloc(artifact.AnchoredNote, limits.max_anchored_notes + 1);
    defer allocator.free(notes);
    for (notes) |*note| note.* = .{
        .anchor = template.anchor,
        .body = "note",
        .related_finding_ids = &.{},
    };
    var result: artifact.RevisionReviewResult = .{
        .schema_version = 1,
        .review_id = finding_set.review_id,
        .target = finding_set.target,
        .findings_digest = identity.Sha256Digest.hash("fixture"),
        .result = .approved,
        .summary = null,
        .finding_dispositions = &.{},
        .anchored_notes = notes[0..limits.max_anchored_notes],
    };
    const exact_result = try result.writeCanonical(allocator);
    allocator.free(exact_result);
    result.anchored_notes = notes;
    try std.testing.expectError(error.LimitExceeded, result.writeCanonical(allocator));

    const related_storage = try allocator.alloc([16]u8, limits.max_related_finding_ids + 1);
    defer allocator.free(related_storage);
    const related = try allocator.alloc(artifact.FindingId, limits.max_related_finding_ids + 1);
    defer allocator.free(related);
    for (related, 0..) |*id, index| {
        id.* = .{ .bytes = try std.fmt.bufPrint(&related_storage[index], "R-{d}", .{index}) };
    }
    notes[0].related_finding_ids = related[0..limits.max_related_finding_ids];
    result.anchored_notes = notes[0..1];
    const exact_related = try result.writeCanonical(allocator);
    allocator.free(exact_related);
    notes[0].related_finding_ids = related;
    try std.testing.expectError(error.LimitExceeded, result.writeCanonical(allocator));
}
