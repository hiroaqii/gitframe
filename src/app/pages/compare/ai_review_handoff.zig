//! Bounded, provider-neutral handoff snapshot owned by the Compare modal.

const std = @import("std");
const ui = @import("chasen_ui");
const app_state = @import("../../state.zig");
const committed_review = @import("../../../committed_review.zig");

pub const max_prompt_bytes: usize = 16 * 1024;

const prompt_prefix =
    "Use the installed skill named `gitframe-ai-review` to review the exact\n" ++
    "committed target below and publish one GitFrame Finding Run.\n" ++
    "\n" ++
    "Follow the skill's complete begin, semantic review, and complete workflow.\n" ++
    "If the skill is unavailable, stop and report that. Do not substitute another\n" ++
    "review workflow.\n" ++
    "\n" ++
    "GitFrame executable: ";
const repository_label = "\nRepository: ";
const base_label = "\nBase OID: ";
const head_label = "\nHead OID: ";
const fixed_prompt_bytes = prompt_prefix.len + repository_label.len + base_label.len + head_label.len;

pub const UnavailableReason = enum {
    repository_unavailable,
    comparison_unavailable_or_stale,
    executable_path_unavailable,
    path_cannot_be_represented_safely,
    handoff_prompt_too_large,
    could_not_build_handoff,

    pub fn text(self: UnavailableReason) []const u8 {
        return switch (self) {
            .repository_unavailable => "Repository unavailable",
            .comparison_unavailable_or_stale => "Comparison unavailable or stale",
            .executable_path_unavailable => "Executable path unavailable",
            .path_cannot_be_represented_safely => "Path cannot be represented safely",
            .handoff_prompt_too_large => "Handoff prompt too large",
            .could_not_build_handoff => "Could not build handoff",
        };
    }
};

pub const OpenInput = struct {
    executable_path: ?[]const u8,
    repository_path: ?[]const u8,
    target: ?committed_review.CommittedReviewTarget,
};

pub const OwnedSnapshot = struct {
    target: committed_review.CommittedReviewTarget,
    canonical_prompt: []u8,

    fn deinit(self: *OwnedSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_prompt);
        self.* = undefined;
    }
};

pub const PromptViewport = struct {
    top_visual_row: usize = 0,
};

pub const Ready = struct {
    snapshot: OwnedSnapshot,
    viewport: PromptViewport = .{},
    latest_copy_generation: u64 = 0,

    fn deinit(self: *Ready, allocator: std.mem.Allocator) void {
        self.snapshot.deinit(allocator);
        self.* = undefined;
    }
};

pub const Content = union(enum) {
    none,
    ready: Ready,
    unavailable: UnavailableReason,
};

pub const Copy = struct {
    modal_instance_id: u64,
    copy_generation: u64,
    prompt: []const u8,
};

pub const CopyAuthority = struct {
    modal_instance_id: u64,
    copy_generation: u64,
};

pub const ScrollAction = enum {
    row_up,
    row_down,
    page_up,
    page_down,
    home,
    end,
};

pub const PromptSize = struct {
    width: u16,
    height: u16,
};

pub const Modal = struct {
    open: bool = false,
    instance_id: u64 = 0,
    content: Content = .none,
    status: app_state.StatusMessage = .{},
    next_instance_id: u64 = 0,

    pub fn begin(self: *Modal, allocator: std.mem.Allocator, input: OpenInput) void {
        self.clearContent(allocator);
        self.status.clear();
        self.next_instance_id +%= 1;
        if (self.next_instance_id == 0) self.next_instance_id = 1;
        self.instance_id = self.next_instance_id;
        self.open = true;
        self.content = prepare(allocator, input);
    }

    pub fn close(self: *Modal, allocator: std.mem.Allocator) void {
        self.clearContent(allocator);
        self.status.clear();
        self.open = false;
        self.instance_id = 0;
    }

    pub fn deinit(self: *Modal, allocator: std.mem.Allocator) void {
        self.clearContent(allocator);
        self.* = .{};
    }

    pub fn ready(self: *const Modal) ?*const Ready {
        if (!self.open) return null;
        return switch (self.content) {
            .ready => |*value| value,
            .none, .unavailable => null,
        };
    }

    pub fn unavailableReason(self: *const Modal) ?UnavailableReason {
        if (!self.open) return null;
        return switch (self.content) {
            .unavailable => |reason| reason,
            .none, .ready => null,
        };
    }

    pub fn statusMessage(self: *Modal) ?*app_state.StatusMessage {
        if (!self.open or self.readyMut() == null) return null;
        return &self.status;
    }

    pub fn beginCopy(self: *Modal) ?Copy {
        const value = self.readyMut() orelse return null;
        self.status.clear();
        value.latest_copy_generation +%= 1;
        if (value.latest_copy_generation == 0) value.latest_copy_generation = 1;
        return .{
            .modal_instance_id = self.instance_id,
            .copy_generation = value.latest_copy_generation,
            .prompt = value.snapshot.canonical_prompt,
        };
    }

    pub fn currentCopyAuthority(self: *const Modal) ?CopyAuthority {
        const value = self.ready() orelse return null;
        return .{
            .modal_instance_id = self.instance_id,
            .copy_generation = value.latest_copy_generation,
        };
    }

    pub fn scroll(self: *Modal, action: ScrollAction, size: PromptSize) void {
        const value = self.readyMut() orelse return;
        const max_offset = promptMaxOffset(value.snapshot.canonical_prompt, size);
        value.viewport.top_visual_row = switch (action) {
            .row_up => value.viewport.top_visual_row -| 1,
            .row_down => @min(value.viewport.top_visual_row +| 1, max_offset),
            .page_up => value.viewport.top_visual_row -| @as(usize, size.height),
            .page_down => @min(value.viewport.top_visual_row +| @as(usize, size.height), max_offset),
            .home => 0,
            .end => max_offset,
        };
    }

    pub fn clampViewport(self: *Modal, size: PromptSize) void {
        const value = self.readyMut() orelse return;
        value.viewport.top_visual_row = @min(
            value.viewport.top_visual_row,
            promptMaxOffset(value.snapshot.canonical_prompt, size),
        );
    }

    fn readyMut(self: *Modal) ?*Ready {
        if (!self.open) return null;
        return switch (self.content) {
            .ready => |*value| value,
            .none, .unavailable => null,
        };
    }

    fn clearContent(self: *Modal, allocator: std.mem.Allocator) void {
        switch (self.content) {
            .ready => |*value| value.deinit(allocator),
            .none, .unavailable => {},
        }
        self.content = .none;
    }
};

pub fn isSafeAbsolutePath(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var iterator = (std.unicode.Utf8View.init(path) catch return false).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0x1f or
            codepoint == 0x7f or
            (codepoint >= 0x80 and codepoint <= 0x9f) or
            codepoint == 0x061c or
            (codepoint >= 0x200e and codepoint <= 0x200f) or
            (codepoint >= 0x2028 and codepoint <= 0x202e) or
            (codepoint >= 0x2066 and codepoint <= 0x2069))
        {
            return false;
        }
    }
    return true;
}

pub fn promptVisualRowCount(prompt: []const u8, width: u16) usize {
    return ui.Paragraph.init(.{ .text = prompt }).lineCount(width);
}

pub fn promptMaxOffset(prompt: []const u8, size: PromptSize) usize {
    return ui.Viewport.init(.{
        .total = promptVisualRowCount(prompt, size.width),
        .height = size.height,
    }).maxOffset();
}

fn prepare(allocator: std.mem.Allocator, input: OpenInput) Content {
    const repository_path = input.repository_path orelse return .{ .unavailable = .repository_unavailable };
    const target = input.target orelse return .{ .unavailable = .comparison_unavailable_or_stale };
    target.validate() catch return .{ .unavailable = .comparison_unavailable_or_stale };
    const executable_path = input.executable_path orelse return .{ .unavailable = .executable_path_unavailable };
    if (!isSafeAbsolutePath(executable_path) or !isSafeAbsolutePath(repository_path)) {
        return .{ .unavailable = .path_cannot_be_represented_safely };
    }

    const prompt_len = canonicalPromptLength(executable_path, repository_path, target) orelse
        return .{ .unavailable = .handoff_prompt_too_large };
    if (prompt_len > max_prompt_bytes) return .{ .unavailable = .handoff_prompt_too_large };
    const prompt = allocator.alloc(u8, prompt_len) catch
        return .{ .unavailable = .could_not_build_handoff };
    const rendered = std.fmt.bufPrint(prompt, "{s}{s}{s}{s}{s}{s}{s}{s}", .{
        prompt_prefix,
        executable_path,
        repository_label,
        repository_path,
        base_label,
        target.base_oid.slice(),
        head_label,
        target.head_oid.slice(),
    }) catch {
        allocator.free(prompt);
        return .{ .unavailable = .could_not_build_handoff };
    };
    std.debug.assert(rendered.len == prompt.len);
    return .{ .ready = .{ .snapshot = .{
        .target = target,
        .canonical_prompt = prompt,
    } } };
}

fn canonicalPromptLength(
    executable_path: []const u8,
    repository_path: []const u8,
    target: committed_review.CommittedReviewTarget,
) ?usize {
    var total = fixed_prompt_bytes;
    for ([_]usize{
        executable_path.len,
        repository_path.len,
        target.base_oid.slice().len,
        target.head_oid.slice().len,
    }) |len| {
        total = std.math.add(usize, total, len) catch return null;
    }
    return total;
}

fn testTarget() committed_review.CommittedReviewTarget {
    const base = committed_review.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111") catch unreachable;
    const head = committed_review.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222") catch unreachable;
    return .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = base,
        .head_oid = head,
        .diff_base_oid = base,
    };
}

test "AI Review Handoff canonical prompt is exact and has no trailing newline" {
    var modal: Modal = .{};
    defer modal.deinit(std.testing.allocator);
    modal.begin(std.testing.allocator, .{
        .executable_path = "/opt/gitframe/bin/gitframe",
        .repository_path = "/work/repository",
        .target = testTarget(),
    });
    const prompt = modal.ready().?.snapshot.canonical_prompt;
    try std.testing.expectEqualStrings(
        "Use the installed skill named `gitframe-ai-review` to review the exact\n" ++
            "committed target below and publish one GitFrame Finding Run.\n\n" ++
            "Follow the skill's complete begin, semantic review, and complete workflow.\n" ++
            "If the skill is unavailable, stop and report that. Do not substitute another\n" ++
            "review workflow.\n\n" ++
            "GitFrame executable: /opt/gitframe/bin/gitframe\n" ++
            "Repository: /work/repository\n" ++
            "Base OID: 1111111111111111111111111111111111111111\n" ++
            "Head OID: 2222222222222222222222222222222222222222",
        prompt,
    );
    try std.testing.expect(prompt[prompt.len - 1] != '\n');
}

test "AI Review Handoff safe path admission covers exact scalar boundaries" {
    const cases = [_]struct { codepoint: u21, accepted: bool }{
        .{ .codepoint = 0x0000, .accepted = false },
        .{ .codepoint = 0x001f, .accepted = false },
        .{ .codepoint = 0x0020, .accepted = true },
        .{ .codepoint = 0x007e, .accepted = true },
        .{ .codepoint = 0x007f, .accepted = false },
        .{ .codepoint = 0x0080, .accepted = false },
        .{ .codepoint = 0x009f, .accepted = false },
        .{ .codepoint = 0x00a0, .accepted = true },
        .{ .codepoint = 0x061c, .accepted = false },
        .{ .codepoint = 0x200e, .accepted = false },
        .{ .codepoint = 0x200f, .accepted = false },
        .{ .codepoint = 0x2028, .accepted = false },
        .{ .codepoint = 0x2029, .accepted = false },
        .{ .codepoint = 0x202a, .accepted = false },
        .{ .codepoint = 0x202e, .accepted = false },
        .{ .codepoint = 0x2066, .accepted = false },
        .{ .codepoint = 0x2069, .accepted = false },
    };
    for (cases) |case| {
        var path_buffer: [5]u8 = undefined;
        path_buffer[0] = '/';
        const scalar_len = try std.unicode.utf8Encode(case.codepoint, path_buffer[1..]);
        try std.testing.expectEqual(case.accepted, isSafeAbsolutePath(path_buffer[0 .. 1 + scalar_len]));
    }
    try std.testing.expect(!isSafeAbsolutePath(&.{ '/', 0xff }));
    try std.testing.expect(!isSafeAbsolutePath("relative/repository"));
}

test "AI Review Handoff accepts exactly 16 KiB and rejects one-byte overflow without partial prompt" {
    const allocator = std.testing.allocator;
    const target = testTarget();
    const executable = "/gitframe";
    const base_len = canonicalPromptLength(executable, "/", target).?;
    const repository_len = max_prompt_bytes - base_len + 1;
    const repository = try allocator.alloc(u8, repository_len + 1);
    defer allocator.free(repository);
    repository[0] = '/';
    @memset(repository[1..], 'r');

    var modal: Modal = .{};
    defer modal.deinit(allocator);
    modal.begin(allocator, .{
        .executable_path = executable,
        .repository_path = repository[0..repository_len],
        .target = target,
    });
    try std.testing.expectEqual(max_prompt_bytes, modal.ready().?.snapshot.canonical_prompt.len);
    const size: PromptSize = .{ .width = 36, .height = 6 };
    const max_offset = promptMaxOffset(modal.ready().?.snapshot.canonical_prompt, size);
    try std.testing.expect(max_offset > 0);
    modal.scroll(.end, size);
    try std.testing.expectEqual(max_offset, modal.ready().?.viewport.top_visual_row);
    try std.testing.expectEqual(max_prompt_bytes, modal.beginCopy().?.prompt.len);

    modal.begin(allocator, .{
        .executable_path = executable,
        .repository_path = repository,
        .target = target,
    });
    try std.testing.expectEqual(UnavailableReason.handoff_prompt_too_large, modal.unavailableReason().?);
    try std.testing.expect(modal.ready() == null);
}

test "AI Review Handoff replacement close and allocation failure have finite ownership terminals" {
    const allocator = std.testing.allocator;
    var modal: Modal = .{};
    defer modal.deinit(allocator);
    modal.begin(allocator, .{
        .executable_path = "/gitframe",
        .repository_path = "/repo",
        .target = testTarget(),
    });
    const first_instance = modal.instance_id;
    try std.testing.expect(modal.ready() != null);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    modal.begin(failing.allocator(), .{
        .executable_path = "/gitframe",
        .repository_path = "/repo",
        .target = testTarget(),
    });
    try std.testing.expect(modal.instance_id != first_instance);
    try std.testing.expectEqual(UnavailableReason.could_not_build_handoff, modal.unavailableReason().?);

    modal.begin(allocator, .{
        .executable_path = "/gitframe",
        .repository_path = "/repo",
        .target = testTarget(),
    });
    try std.testing.expect(modal.ready() != null);
    modal.begin(allocator, .{
        .executable_path = "/gitframe",
        .repository_path = null,
        .target = testTarget(),
    });
    try std.testing.expectEqual(UnavailableReason.repository_unavailable, modal.unavailableReason().?);
    modal.close(allocator);
    try std.testing.expect(!modal.open);
    try std.testing.expect(modal.ready() == null);
}

test "AI Review Handoff viewport reaches both ends and copy authority ignores scrolling" {
    var modal: Modal = .{};
    defer modal.deinit(std.testing.allocator);
    modal.begin(std.testing.allocator, .{
        .executable_path = "/a/very/long/path/to/the/running/gitframe/executable",
        .repository_path = "/a/very/long/path/to/the/repository/under/review",
        .target = testTarget(),
    });
    const size: PromptSize = .{ .width = 24, .height = 4 };
    const prompt = modal.ready().?.snapshot.canonical_prompt;
    const max_offset = promptMaxOffset(prompt, size);
    try std.testing.expect(max_offset > 0);
    modal.scroll(.end, size);
    try std.testing.expectEqual(max_offset, modal.ready().?.viewport.top_visual_row);
    const copy = modal.beginCopy().?;
    try std.testing.expectEqualStrings(prompt, copy.prompt);
    modal.scroll(.home, size);
    try std.testing.expectEqual(@as(usize, 0), modal.ready().?.viewport.top_visual_row);
    try std.testing.expectEqualStrings(copy.prompt, modal.ready().?.snapshot.canonical_prompt);
    modal.scroll(.page_down, size);
    try std.testing.expectEqual(@min(@as(usize, size.height), max_offset), modal.ready().?.viewport.top_visual_row);
    modal.scroll(.row_up, size);
    try std.testing.expectEqual(@min(@as(usize, size.height), max_offset) -| 1, modal.ready().?.viewport.top_visual_row);
    modal.scroll(.end, size);
    const resized: PromptSize = .{ .width = 120, .height = 20 };
    const resized_max_offset = promptMaxOffset(prompt, resized);
    modal.clampViewport(resized);
    try std.testing.expectEqual(resized_max_offset, modal.ready().?.viewport.top_visual_row);
}
