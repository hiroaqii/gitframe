//! Parse-only ownership for one raw diff component of a Review projection.
//!
//! A mixed staged/unstaged presentation first needs the exact Git patch and
//! parsed hunk authority, but syntax, tree, and rendered-row decoration are
//! substantially more expensive. This owner makes that boundary explicit
//! without weakening the ordinary `LoadedDiffBundle`: it owns only the raw
//! bytes, parsed document, text-safety classification, and raw fingerprint.
//!
//! Every successful combined presentation is built eagerly, while a
//! same-generation parse-only copy remains independently replaceable action
//! authority. This permits retaining an old decorated presentation while
//! installing fresh authority without representing a partially initialized
//! loaded diff.

const std = @import("std");
const content_fingerprint = @import("../content_fingerprint.zig");
const diff_parser = @import("../diff/parser.zig");
const text_eligibility = @import("../diff/text_eligibility.zig");

pub const ParsedComponent = struct {
    arena: ?std.heap.ArenaAllocator,
    text: []const u8,
    document: diff_parser.DiffDocument,
    file_text_eligibility: []const text_eligibility.FileTextEligibility,
    fingerprint: content_fingerprint.Fingerprint,

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !ParsedComponent {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        // DiffDocument strings borrow from this copy. Parser arrays and the
        // eligibility sidecar deliberately share the same cleanup boundary.
        const copied = try arena_allocator.dupe(u8, bytes);
        const document = try diff_parser.parse(arena_allocator, copied);
        const eligibility = try text_eligibility.classifyDocument(arena_allocator, document);

        return .{
            .arena = arena,
            .text = copied,
            .document = document,
            .file_text_eligibility = eligibility,
            .fingerprint = content_fingerprint.Fingerprint.init(bytes),
        };
    }

    pub fn deinit(self: *ParsedComponent) void {
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
    }

    /// Transfer the complete backing arena to the eager decoration owner.
    /// After this call `deinit` is intentionally a no-op.
    pub fn takeArena(self: *ParsedComponent) std.heap.ArenaAllocator {
        const arena = self.arena.?;
        self.arena = null;
        return arena;
    }

    pub fn fileTextSelectable(self: *const ParsedComponent, file_index: usize) bool {
        std.debug.assert(self.file_text_eligibility.len == self.document.files.len);
        std.debug.assert(file_index < self.file_text_eligibility.len);
        return self.file_text_eligibility[file_index].selectable();
    }
};

test "parsed projection component owns exact raw bytes model eligibility and fingerprint" {
    const patch =
        "diff --git a/a.zig b/a.zig\n" ++
        "--- a/a.zig\n" ++
        "+++ b/a.zig\n" ++
        "@@ -1 +1 @@\n" ++
        "-const old = 1;\n" ++
        "+const new = 2;\n";
    const input = try std.testing.allocator.dupe(u8, patch);
    defer std.testing.allocator.free(input);

    var component = try ParsedComponent.parse(std.testing.allocator, input);
    defer component.deinit();
    input[0] = 'x';

    try std.testing.expectEqualStrings(patch, component.text);
    try std.testing.expect(component.fingerprint.eql(content_fingerprint.Fingerprint.init(patch)));
    try std.testing.expectEqual(@as(usize, 1), component.document.files.len);
    try std.testing.expectEqualStrings("const new = 2;", component.document.files[0].hunks[0].lines[1].text);
    try std.testing.expect(component.fileTextSelectable(0));
}

test "parsed projection component keeps invalid text inert without presentation decoration" {
    const patch =
        "diff --git a/a b/a\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+bad\xff\n";
    var component = try ParsedComponent.parse(std.testing.allocator, patch);
    defer component.deinit();

    try std.testing.expect(!component.fileTextSelectable(0));
    try std.testing.expect(!@hasField(ParsedComponent, "syntax_spans"));
    try std.testing.expect(!@hasField(ParsedComponent, "tree"));
    try std.testing.expect(!@hasField(ParsedComponent, "rendered_line_cache"));
    try std.testing.expect(!@hasField(ParsedComponent, "collapsed_hunks"));
    try std.testing.expect(!@hasField(ParsedComponent, "visible_nodes"));
}

test "parsed projection component releases every allocation failure" {
    const patch =
        "diff --git a/a b/a\n" ++
        "--- a/a\n" ++
        "+++ b/a\n" ++
        "@@ -1 +1 @@\n" ++
        "-old\n" ++
        "+new\n";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn parse(allocator: std.mem.Allocator, bytes: []const u8) !void {
            var component = try ParsedComponent.parse(allocator, bytes);
            defer component.deinit();
        }
    }.parse, .{patch});
}
