//! Canonical identity for one normalized Review diff presentation.
//!
//! This module deliberately separates what a person can see, navigate, search,
//! select, or copy from the index-dependent authority used by stage operations.
//! Callers provide an already-normalized `A = HEAD` to `C = working tree`
//! `FileDiff`; raw cached/unstaged component metadata and `B = index` blob IDs
//! are not presentation identity.
//!
//! The BLAKE3 fingerprint is only a cheap candidate hint. Reuse must still be
//! admitted with `exactEqual`, whose comparison is allocation-free. Keeping the
//! two operations here makes their shared field checklist reviewable:
//!
//! - resolved old/new/display paths;
//! - ordered visible canonical metadata facts and binary state;
//! - ordered hunk coordinates, counts, and sections; and
//! - ordered line kinds, text, and old/new coordinates.
//!
//! Stage state, syntax/action origins, revisions, request IDs, and UI state are
//! intentionally absent. If a new field becomes visible to render, navigation,
//! search, copy, or selection, add it to both operations and the mutation tests
//! in this file before using it as part of a retained presentation.

const std = @import("std");
const diff_file = @import("file.zig");
const diff_parser = @import("parser.zig");
const diff_view_model = @import("view_model.zig");

pub const Fingerprint = struct {
    digest: [32]u8,

    pub fn eql(lhs: Fingerprint, rhs: Fingerprint) bool {
        return std.mem.eql(u8, &lhs.digest, &rhs.digest);
    }
};

/// A typed, allocation-free view over metadata rows exposed by the diff body.
///
/// Known Git facts receive distinct tags. Unknown visible rows remain exact
/// `.other` facts so adding or changing rendered metadata cannot accidentally
/// compare equal. Component-only `index` and path-header rows are skipped by the
/// same visibility contract used by the body view model.
pub const CanonicalMetadata = struct {
    lines: []const []const u8,

    pub fn init(lines: []const []const u8) CanonicalMetadata {
        return .{ .lines = lines };
    }

    pub fn iterator(self: CanonicalMetadata) MetadataIterator {
        return .{ .lines = self.lines };
    }

    pub fn count(self: CanonicalMetadata) usize {
        var result: usize = 0;
        var iter = self.iterator();
        while (iter.next() != null) result += 1;
        return result;
    }

    pub fn exactEqual(lhs: CanonicalMetadata, rhs: CanonicalMetadata) bool {
        var left = lhs.iterator();
        var right = rhs.iterator();
        while (true) {
            const left_fact = left.next();
            const right_fact = right.next();
            if (left_fact == null or right_fact == null) return left_fact == null and right_fact == null;
            if (!left_fact.?.exactEqual(right_fact.?)) return false;
        }
    }
};

pub const MetadataFact = struct {
    kind: Kind,
    value: []const u8,

    pub const Kind = enum(u8) {
        old_mode,
        new_mode,
        new_file_mode,
        deleted_file_mode,
        similarity_index,
        dissimilarity_index,
        rename_from,
        rename_to,
        copy_from,
        copy_to,
        binary_files,
        other,
    };

    pub fn exactEqual(lhs: MetadataFact, rhs: MetadataFact) bool {
        return lhs.kind == rhs.kind and std.mem.eql(u8, lhs.value, rhs.value);
    }
};

pub const MetadataIterator = struct {
    lines: []const []const u8,
    index: usize = 0,

    pub fn next(self: *MetadataIterator) ?MetadataFact {
        while (self.index < self.lines.len) {
            const line = self.lines[self.index];
            self.index += 1;
            if (!diff_view_model.isVisibleMetadataLine(line)) continue;
            return classifyMetadata(line);
        }
        return null;
    }
};

/// Compute a tagged, streaming hint for one normalized projected file.
///
/// No concatenation buffer is allocated. A matching result is insufficient for
/// reuse until `exactEqual` succeeds against the still-live presentation.
pub fn fingerprint(file: diff_parser.FileDiff) Fingerprint {
    var hasher = std.crypto.hash.Blake3.init(.{});
    writeBytes(&hasher, .domain, "gitframe.projected-file-presentation.v1");

    const paths = canonicalPaths(file);
    writeOptionalBytes(&hasher, .old_path, paths.old);
    writeOptionalBytes(&hasher, .new_path, paths.new);
    writeBytes(&hasher, .display_path, paths.display);

    const metadata = CanonicalMetadata.init(file.metadata);
    writeU64(&hasher, .metadata_count, metadata.count());
    var metadata_iter = metadata.iterator();
    while (metadata_iter.next()) |fact| {
        writeByte(&hasher, .metadata_kind, @intFromEnum(fact.kind));
        writeBytes(&hasher, .metadata_value, fact.value);
    }

    writeByte(&hasher, .binary, @intFromBool(file.is_binary));
    writeU64(&hasher, .hunk_count, file.hunks.len);
    for (file.hunks) |hunk| {
        writeTag(&hasher, .hunk);
        writeU32(&hasher, .hunk_old_start, hunk.old_start);
        writeU32(&hasher, .hunk_old_count, hunk.old_count);
        writeU32(&hasher, .hunk_new_start, hunk.new_start);
        writeU32(&hasher, .hunk_new_count, hunk.new_count);
        writeBytes(&hasher, .hunk_section, hunk.section);
        writeU64(&hasher, .line_count, hunk.lines.len);
        for (hunk.lines) |line| {
            writeTag(&hasher, .line);
            writeByte(&hasher, .line_kind, @intFromEnum(line.kind));
            writeBytes(&hasher, .line_text, line.text);
            writeOptionalU32(&hasher, .line_old_coordinate, line.old_line);
            writeOptionalU32(&hasher, .line_new_coordinate, line.new_line);
        }
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .digest = digest };
}

/// Allocation-free correctness comparison for two normalized presentations.
pub fn exactEqual(lhs: diff_parser.FileDiff, rhs: diff_parser.FileDiff) bool {
    const left_paths = canonicalPaths(lhs);
    const right_paths = canonicalPaths(rhs);
    if (!optionalBytesEqual(left_paths.old, right_paths.old) or
        !optionalBytesEqual(left_paths.new, right_paths.new) or
        !std.mem.eql(u8, left_paths.display, right_paths.display))
    {
        return false;
    }

    if (!CanonicalMetadata.init(lhs.metadata).exactEqual(CanonicalMetadata.init(rhs.metadata))) return false;
    if (lhs.is_binary != rhs.is_binary or lhs.hunks.len != rhs.hunks.len) return false;

    for (lhs.hunks, rhs.hunks) |left_hunk, right_hunk| {
        if (left_hunk.old_start != right_hunk.old_start or
            left_hunk.old_count != right_hunk.old_count or
            left_hunk.new_start != right_hunk.new_start or
            left_hunk.new_count != right_hunk.new_count or
            !std.mem.eql(u8, left_hunk.section, right_hunk.section) or
            left_hunk.lines.len != right_hunk.lines.len)
        {
            return false;
        }

        for (left_hunk.lines, right_hunk.lines) |left_line, right_line| {
            if (left_line.kind != right_line.kind or
                !std.mem.eql(u8, left_line.text, right_line.text) or
                left_line.old_line != right_line.old_line or
                left_line.new_line != right_line.new_line)
            {
                return false;
            }
        }
    }
    return true;
}

const CanonicalPaths = struct {
    old: ?[]const u8,
    new: ?[]const u8,
    display: []const u8,
};

fn canonicalPaths(file: diff_parser.FileDiff) CanonicalPaths {
    const old = canonicalOptionalPath(file.old_path);
    const new = canonicalOptionalPath(file.new_path);
    return .{
        .old = old,
        .new = new,
        // `displayPath` normally resolves to one of these canonical sides. Its
        // header fallback is retained because that exact value is exposed by
        // the current Review chrome for metadata-only inputs.
        .display = if (new) |path| path else if (old) |path| path else diff_file.displayPath(file),
    };
}

fn canonicalOptionalPath(path: ?[]const u8) ?[]const u8 {
    return diff_file.stripGitPathPrefix(path orelse return null);
}

fn classifyMetadata(line: []const u8) MetadataFact {
    const known = [_]struct { prefix: []const u8, kind: MetadataFact.Kind }{
        .{ .prefix = "old mode ", .kind = .old_mode },
        .{ .prefix = "new mode ", .kind = .new_mode },
        .{ .prefix = "new file mode ", .kind = .new_file_mode },
        .{ .prefix = "deleted file mode ", .kind = .deleted_file_mode },
        .{ .prefix = "similarity index ", .kind = .similarity_index },
        .{ .prefix = "dissimilarity index ", .kind = .dissimilarity_index },
        .{ .prefix = "rename from ", .kind = .rename_from },
        .{ .prefix = "rename to ", .kind = .rename_to },
        .{ .prefix = "copy from ", .kind = .copy_from },
        .{ .prefix = "copy to ", .kind = .copy_to },
        .{ .prefix = "Binary files ", .kind = .binary_files },
    };
    inline for (known) |entry| {
        if (std.mem.startsWith(u8, line, entry.prefix)) {
            return .{ .kind = entry.kind, .value = line[entry.prefix.len..] };
        }
    }
    return .{ .kind = .other, .value = line };
}

fn optionalBytesEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs) |left| {
        const right = rhs orelse return false;
        return std.mem.eql(u8, left, right);
    }
    return rhs == null;
}

const HashTag = enum(u8) {
    domain,
    old_path,
    new_path,
    display_path,
    metadata_count,
    metadata_kind,
    metadata_value,
    binary,
    hunk_count,
    hunk,
    hunk_old_start,
    hunk_old_count,
    hunk_new_start,
    hunk_new_count,
    hunk_section,
    line_count,
    line,
    line_kind,
    line_text,
    line_old_coordinate,
    line_new_coordinate,
};

fn writeTag(hasher: *std.crypto.hash.Blake3, tag: HashTag) void {
    hasher.update(&.{@intFromEnum(tag)});
}

fn writeByte(hasher: *std.crypto.hash.Blake3, tag: HashTag, value: u8) void {
    writeTag(hasher, tag);
    hasher.update(&.{value});
}

fn writeU32(hasher: *std.crypto.hash.Blake3, tag: HashTag, value: u32) void {
    writeTag(hasher, tag);
    var bytes: [@sizeOf(u32)]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hasher.update(&bytes);
}

fn writeU64(hasher: *std.crypto.hash.Blake3, tag: HashTag, value: usize) void {
    writeTag(hasher, tag);
    var bytes: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hasher.update(&bytes);
}

fn writeBytes(hasher: *std.crypto.hash.Blake3, tag: HashTag, value: []const u8) void {
    writeTag(hasher, tag);
    var length: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(value.len), .little);
    hasher.update(&length);
    hasher.update(value);
}

fn writeOptionalBytes(hasher: *std.crypto.hash.Blake3, tag: HashTag, value: ?[]const u8) void {
    writeTag(hasher, tag);
    if (value) |bytes| {
        hasher.update(&.{1});
        var length: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(bytes.len), .little);
        hasher.update(&length);
        hasher.update(bytes);
    } else {
        hasher.update(&.{0});
    }
}

fn writeOptionalU32(hasher: *std.crypto.hash.Blake3, tag: HashTag, value: ?u32) void {
    writeTag(hasher, tag);
    if (value) |number| {
        hasher.update(&.{1});
        var bytes: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, &bytes, number, .little);
        hasher.update(&bytes);
    } else {
        hasher.update(&.{0});
    }
}

const base_lines = [_]diff_parser.DiffLine{
    .{ .kind = .removed, .text = "const value = 1;", .old_line = 10 },
    .{ .kind = .added, .text = "const value = 2;", .new_line = 10 },
    .{ .kind = .metadata, .text = "\\ No newline at end of file" },
};

const second_lines = [_]diff_parser.DiffLine{
    .{ .kind = .context, .text = "return value;", .old_line = 20, .new_line = 20 },
};

const base_hunks = [_]diff_parser.Hunk{
    .{
        .old_start = 10,
        .old_count = 1,
        .new_start = 10,
        .new_count = 1,
        .section = "fn 計算()",
        .lines = &base_lines,
    },
    .{
        .old_start = 20,
        .old_count = 1,
        .new_start = 20,
        .new_count = 1,
        .section = "fn read()",
        .lines = &second_lines,
    },
};

fn baseFile() diff_parser.FileDiff {
    return .{
        .header = "diff --git a/src/例.zig b/src/例.zig",
        .old_path = "a/src/例.zig",
        .new_path = "b/src/例.zig",
        .metadata = &.{
            "index 1111111..2222222 100644",
            "--- a/src/例.zig",
            "+++ b/src/例.zig",
            "old mode 100644",
            "new mode 100755",
        },
        .hunks = &base_hunks,
    };
}

fn expectMutationUnequal(base: diff_parser.FileDiff, changed: diff_parser.FileDiff) !void {
    try std.testing.expect(!exactEqual(base, changed));
    try std.testing.expect(!fingerprint(base).eql(fingerprint(changed)));
}

test "presentation identity normalizes paths and excludes component-only metadata" {
    const base = baseFile();
    var equivalent = base;
    equivalent.header = "authority-only header changed";
    equivalent.old_path = "src/例.zig";
    equivalent.new_path = "src/例.zig";
    equivalent.metadata = &.{
        "index aaaaaaa..bbbbbbb 100755",
        "--- another-old-header",
        "+++ another-new-header",
        "old mode 100644",
        "new mode 100755",
    };

    try std.testing.expect(exactEqual(base, equivalent));
    try std.testing.expect(fingerprint(base).eql(fingerprint(equivalent)));
}

test "canonical metadata is typed ordered and preserves unknown visible rows" {
    const lines = [_][]const u8{
        "index hidden..value 100644",
        "rename from src/old.zig",
        "copy to src/copied.zig",
        "custom visible metadata",
    };
    var iterator = CanonicalMetadata.init(&lines).iterator();
    const first = iterator.next().?;
    try std.testing.expectEqual(MetadataFact.Kind.rename_from, first.kind);
    try std.testing.expectEqualStrings("src/old.zig", first.value);
    const second = iterator.next().?;
    try std.testing.expectEqual(MetadataFact.Kind.copy_to, second.kind);
    try std.testing.expectEqualStrings("src/copied.zig", second.value);
    const third = iterator.next().?;
    try std.testing.expectEqual(MetadataFact.Kind.other, third.kind);
    try std.testing.expectEqualStrings("custom visible metadata", third.value);
    try std.testing.expect(iterator.next() == null);
}

test "visible canonical metadata facts and order affect identity" {
    const base = baseFile();
    const visible_facts = [_][]const u8{
        "old mode 100600",
        "new mode 100700",
        "new file mode 100600",
        "deleted file mode 100600",
        "similarity index 90%",
        "dissimilarity index 10%",
        "rename from src/old.zig",
        "rename to src/new.zig",
        "copy from src/source.zig",
        "copy to src/copy.zig",
        "Binary files a/bin and b/bin differ",
        "custom visible metadata",
    };
    for (visible_facts) |line| {
        var changed = base;
        changed.metadata = &.{line};
        try expectMutationUnequal(base, changed);
    }

    var reordered = base;
    reordered.metadata = &.{ "new mode 100755", "old mode 100644" };
    try expectMutationUnequal(base, reordered);
}

test "paths binary and header fallback affect identity" {
    const base = baseFile();
    var changed = base;
    changed.old_path = "a/src/old.zig";
    try expectMutationUnequal(base, changed);

    changed = base;
    changed.new_path = "b/src/new.zig";
    try expectMutationUnequal(base, changed);

    changed = base;
    changed.is_binary = true;
    try expectMutationUnequal(base, changed);

    const metadata_only: diff_parser.FileDiff = .{
        .header = "metadata-only-one",
        .metadata = &.{},
        .hunks = &.{},
    };
    var other_header = metadata_only;
    other_header.header = "metadata-only-two";
    try expectMutationUnequal(metadata_only, other_header);

    try std.testing.expect(exactEqual(metadata_only, metadata_only));
    try std.testing.expect(fingerprint(metadata_only).eql(fingerprint(metadata_only)));
}

test "every hunk field and hunk order affect identity" {
    const base = baseFile();
    var changed_hunks = base_hunks;
    var changed = base;

    changed.hunks = base_hunks[0..1];
    try expectMutationUnequal(base, changed);

    changed_hunks = .{ base_hunks[1], base_hunks[0] };
    changed = base;
    changed.hunks = &changed_hunks;
    try expectMutationUnequal(base, changed);

    changed_hunks = base_hunks;
    changed_hunks[0].old_start += 1;
    changed.hunks = &changed_hunks;
    try expectMutationUnequal(base, changed);

    changed_hunks = base_hunks;
    changed_hunks[0].old_count += 1;
    changed.hunks = &changed_hunks;
    try expectMutationUnequal(base, changed);

    changed_hunks = base_hunks;
    changed_hunks[0].new_start += 1;
    changed.hunks = &changed_hunks;
    try expectMutationUnequal(base, changed);

    changed_hunks = base_hunks;
    changed_hunks[0].new_count += 1;
    changed.hunks = &changed_hunks;
    try expectMutationUnequal(base, changed);

    changed_hunks = base_hunks;
    changed_hunks[0].section = "fn changed()";
    changed.hunks = &changed_hunks;
    try expectMutationUnequal(base, changed);
}

test "every rendered line field and line order affect identity" {
    const base = baseFile();
    var changed_lines = base_lines;
    var changed_hunks = base_hunks;
    var changed = base;

    changed_hunks[0].lines = base_lines[0..2];
    changed.hunks = &changed_hunks;
    try expectMutationUnequal(base, changed);

    changed_lines = .{ base_lines[1], base_lines[0], base_lines[2] };
    changed_hunks = base_hunks;
    changed_hunks[0].lines = &changed_lines;
    changed.hunks = &changed_hunks;
    try expectMutationUnequal(base, changed);

    changed_lines = base_lines;
    changed_lines[0].kind = .context;
    changed_hunks[0].lines = &changed_lines;
    try expectMutationUnequal(base, changed);

    changed_lines = base_lines;
    changed_lines[0].text = "const value = 9;";
    changed_hunks[0].lines = &changed_lines;
    try expectMutationUnequal(base, changed);

    changed_lines = base_lines;
    changed_lines[0].old_line = 11;
    changed_hunks[0].lines = &changed_lines;
    try expectMutationUnequal(base, changed);

    changed_lines = base_lines;
    changed_lines[0].new_line = 10;
    changed_hunks[0].lines = &changed_lines;
    try expectMutationUnequal(base, changed);
}

test "tagged encoding distinguishes empty and absent optional paths" {
    const empty_path: diff_parser.FileDiff = .{
        .header = "",
        .old_path = "",
        .new_path = "",
        .metadata = &.{},
        .hunks = &.{},
    };
    const absent_path: diff_parser.FileDiff = .{
        .header = "",
        .metadata = &.{},
        .hunks = &.{},
    };
    try expectMutationUnequal(empty_path, absent_path);
}

test "tagged encoding distinguishes metadata concatenation boundaries" {
    const first: diff_parser.FileDiff = .{
        .header = "same",
        .metadata = &.{ "custom ab", "custom c" },
        .hunks = &.{},
    };
    const second: diff_parser.FileDiff = .{
        .header = "same",
        .metadata = &.{ "custom a", "custom bc" },
        .hunks = &.{},
    };
    try expectMutationUnequal(first, second);
}

test "same A C component pair stays equal when B partition and origins change" {
    const before_cached_text =
        \\diff --git a/src/pair_fixture.zig b/src/pair_fixture.zig
        \\index 1111111..2222222 100644
        \\--- a/src/pair_fixture.zig
        \\+++ b/src/pair_fixture.zig
        \\@@ -3,1 +3,1 @@
        \\-const alpha: usize = 1;
        \\+const alpha: usize = 10;
        \\
    ;
    const before_unstaged_text =
        \\diff --git a/src/pair_fixture.zig b/src/pair_fixture.zig
        \\index 2222222..4444444 100644
        \\--- a/src/pair_fixture.zig
        \\+++ b/src/pair_fixture.zig
        \\@@ -8,1 +8,1 @@
        \\-const beta: usize = 2;
        \\+const beta: usize = 20;
        \\@@ -13,1 +13,1 @@
        \\-const gamma: usize = 3;
        \\+const gamma: usize = 30;
        \\
    ;
    const after_cached_text =
        \\diff --git a/src/pair_fixture.zig b/src/pair_fixture.zig
        \\index 1111111..3333333 100644
        \\--- a/src/pair_fixture.zig
        \\+++ b/src/pair_fixture.zig
        \\@@ -3,1 +3,1 @@
        \\-const alpha: usize = 1;
        \\+const alpha: usize = 10;
        \\@@ -8,1 +8,1 @@
        \\-const beta: usize = 2;
        \\+const beta: usize = 20;
        \\
    ;
    const after_unstaged_text =
        \\diff --git a/src/pair_fixture.zig b/src/pair_fixture.zig
        \\index 3333333..4444444 100644
        \\--- a/src/pair_fixture.zig
        \\+++ b/src/pair_fixture.zig
        \\@@ -13,1 +13,1 @@
        \\-const gamma: usize = 3;
        \\+const gamma: usize = 30;
        \\
    ;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const hunk_projection = @import("hunk_projection.zig");

    const before_cached = try diff_parser.parse(allocator, before_cached_text);
    const before_unstaged = try diff_parser.parse(allocator, before_unstaged_text);
    const after_cached = try diff_parser.parse(allocator, after_cached_text);
    const after_unstaged = try diff_parser.parse(allocator, after_unstaged_text);
    const before = try hunk_projection.build(allocator, before_cached.files[0], before_unstaged.files[0]);
    const after = try hunk_projection.build(allocator, after_cached.files[0], after_unstaged.files[0]);

    try std.testing.expect(!std.mem.eql(u8, before.file.metadata[0], after.file.metadata[0]));
    try std.testing.expect(before.hunk_stage_states[1] != after.hunk_stage_states[1]);
    try std.testing.expect(exactEqual(before.file, after.file));
    try std.testing.expect(fingerprint(before.file).eql(fingerprint(after.file)));

    var changed = after.file;
    changed.metadata = &.{ "old mode 100644", "new mode 100755" };
    try expectMutationUnequal(before.file, changed);
    changed = after.file;
    changed.new_path = "b/src/other.zig";
    try expectMutationUnequal(before.file, changed);

    var changed_hunks = try allocator.dupe(diff_parser.Hunk, after.file.hunks);
    var changed_lines = try allocator.dupe(diff_parser.DiffLine, changed_hunks[0].lines);
    changed_lines[0].text = "changed rendered text";
    changed_hunks[0].lines = changed_lines;
    changed = after.file;
    changed.hunks = changed_hunks;
    try expectMutationUnequal(before.file, changed);
}
