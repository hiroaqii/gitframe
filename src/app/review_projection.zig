const std = @import("std");
const diff_hunk_projection = @import("../diff/hunk_projection.zig");
const app_load = @import("load.zig");

pub const max_generated_file_bytes = 1024 * 1024;

pub const Kind = enum {
    cached_diff,
    generated_added_file,
    combined_hunks,
};

pub const SourceKind = enum {
    unstaged,
    cached,
    other,
};

pub const Request = struct {
    id: u64,
    repo_root: []u8,
    path_key: []u8,
    kind: Kind,
    source_kind: SourceKind,
    load_generation: u64,
    status_generation: u64,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path_key);
        self.* = undefined;
    }

    pub fn matchesBorrowed(self: Request, repo_root: []const u8, path_key: []const u8, kind: Kind, source_kind: SourceKind, load_generation: u64, status_generation: u64) bool {
        return self.kind == kind and
            self.source_kind == source_kind and
            self.load_generation == load_generation and
            self.status_generation == status_generation and
            std.mem.eql(u8, self.repo_root, repo_root) and
            std.mem.eql(u8, self.path_key, path_key);
    }
};

pub const GeneratedFile = struct {
    path: []const u8,
    lines: []const []const u8,
    truncated: bool = false,
};

pub const GeneratedFileBundle = struct {
    arena: ?std.heap.ArenaAllocator,
    file: GeneratedFile,

    pub fn deinit(self: *GeneratedFileBundle) void {
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.file = undefined;
    }
};

pub const CombinedHunkBundle = struct {
    arena: ?std.heap.ArenaAllocator,
    projection: diff_hunk_projection.Projection,
    cached_bundle: app_load.LoadedDiffBundle,
    unstaged_bundle: app_load.LoadedDiffBundle,

    pub fn deinit(self: *CombinedHunkBundle) void {
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.cached_bundle.deinit();
        self.unstaged_bundle.deinit();
        self.projection = undefined;
    }
};

pub const StatusBody = struct {
    path: []u8,
    message: []u8,

    pub fn deinit(self: *StatusBody, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const Ready = union(enum) {
    cached_diff: app_load.LoadedDiffBundle,
    generated_added_file: GeneratedFileBundle,
    combined_hunks: CombinedHunkBundle,
    status_body: StatusBody,

    pub fn deinit(self: *Ready, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .cached_diff => |*bundle| bundle.deinit(),
            .generated_added_file => |*bundle| bundle.deinit(),
            .combined_hunks => |*bundle| bundle.deinit(),
            .status_body => |*body| body.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const TaskResult = union(enum) {
    ready: Ready,
    failed: StatusBody,
    failed_static: []const u8,

    pub fn deinit(self: *TaskResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |*ready| ready.deinit(allocator),
            .failed => |*body| body.deinit(allocator),
            .failed_static => {},
        }
        self.* = undefined;
    }
};

pub const Finished = struct {
    request: Request,
    result: TaskResult,

    pub fn deinit(self: *Finished, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
        self.result.deinit(allocator);
    }
};

pub const State = union(enum) {
    idle,
    pending: Request,
    ready: struct {
        request: Request,
        value: Ready,
    },
    failed: struct {
        request: Request,
        body: StatusBody,
    },

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .idle => {},
            .pending => |*request| request.deinit(allocator),
            .ready => |*ready| {
                ready.request.deinit(allocator);
                ready.value.deinit(allocator);
            },
            .failed => |*failed| {
                failed.request.deinit(allocator);
                failed.body.deinit(allocator);
            },
        }
        self.* = .idle;
    }

    pub fn matches(self: State, repo_root: []const u8, path_key: []const u8, kind: Kind, source_kind: SourceKind, load_generation: u64, status_generation: u64) bool {
        return switch (self) {
            .idle => false,
            .pending => |request| request.matchesBorrowed(repo_root, path_key, kind, source_kind, load_generation, status_generation),
            .ready => |ready| ready.request.matchesBorrowed(repo_root, path_key, kind, source_kind, load_generation, status_generation),
            .failed => |failed| failed.request.matchesBorrowed(repo_root, path_key, kind, source_kind, load_generation, status_generation),
        };
    }
};

pub fn cloneRequest(
    allocator: std.mem.Allocator,
    id: u64,
    repo_root: []const u8,
    path_key: []const u8,
    kind: Kind,
    source_kind: SourceKind,
    load_generation: u64,
    status_generation: u64,
) !Request {
    const owned_root = try allocator.dupe(u8, repo_root);
    errdefer allocator.free(owned_root);
    const owned_path = try allocator.dupe(u8, path_key);
    return .{
        .id = id,
        .repo_root = owned_root,
        .path_key = owned_path,
        .kind = kind,
        .source_kind = source_kind,
        .load_generation = load_generation,
        .status_generation = status_generation,
    };
}

pub fn statusBodyAlloc(allocator: std.mem.Allocator, path: []const u8, comptime fmt: []const u8, args: anytype) !StatusBody {
    return .{
        .path = try allocator.dupe(u8, path),
        .message = try std.fmt.allocPrint(allocator, fmt, args),
    };
}

pub fn generatedFileFromContent(allocator: std.mem.Allocator, path: []const u8, content: []const u8, truncated: bool) !GeneratedFileBundle {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const copied_path = try arena_allocator.dupe(u8, path);
    const copied_content = try arena_allocator.dupe(u8, content);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(arena_allocator);

    var start: usize = 0;
    while (start < copied_content.len) {
        const end = std.mem.indexOfScalarPos(u8, copied_content, start, '\n') orelse copied_content.len;
        const raw_line = copied_content[start..end];
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        try lines.append(arena_allocator, line);
        start = if (end < copied_content.len) end + 1 else copied_content.len;
    }
    if (copied_content.len == 0) try lines.append(arena_allocator, "");

    return .{
        .arena = arena,
        .file = .{
            .path = copied_path,
            .lines = try lines.toOwnedSlice(arena_allocator),
            .truncated = truncated,
        },
    };
}

test "generated file splits content lines in an owned arena" {
    var bundle = try generatedFileFromContent(std.testing.allocator, "src/new.zig", "one\ntwo\n", false);
    defer bundle.deinit();

    try std.testing.expectEqualStrings("src/new.zig", bundle.file.path);
    try std.testing.expectEqual(@as(usize, 2), bundle.file.lines.len);
    try std.testing.expectEqualStrings("one", bundle.file.lines[0]);
    try std.testing.expectEqualStrings("two", bundle.file.lines[1]);
}

test "state matches projection request identity" {
    var request = try cloneRequest(std.testing.allocator, 1, "/repo", "src/main.zig", .cached_diff, .unstaged, 10, 20);
    defer request.deinit(std.testing.allocator);

    const state = State{ .pending = request };

    try std.testing.expect(state.matches("/repo", "src/main.zig", .cached_diff, .unstaged, 10, 20));
    try std.testing.expect(!state.matches("/repo", "src/main.zig", .generated_added_file, .unstaged, 10, 20));
    try std.testing.expect(!state.matches("/repo", "src/main.zig", .cached_diff, .cached, 10, 20));
    try std.testing.expect(!state.matches("/repo", "src/main.zig", .cached_diff, .unstaged, 11, 20));
    try std.testing.expect(!state.matches("/other", "src/main.zig", .cached_diff, .unstaged, 10, 20));
}
