//! Stash writes use the same descriptor and controlled environment as local Git actions.
const std = @import("std");
const command = @import("command.zig");
const operations = @import("operations.zig");
const status = @import("status.zig");

pub const Scope = enum {
    all,
    staged,

    pub fn label(self: Scope) []const u8 {
        return if (self == .all) "All changes" else "Staged changes only";
    }
};

pub const Entry = struct {
    selector: []const u8,
    oid: []const u8,
    created: i64,
    message: []const u8,
};

/// Entries borrow the owned command output. Display escaping never changes identity.
pub const Catalog = struct {
    bytes: []u8,
    entries: []Entry,

    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const ListResult = union(enum) {
    empty,
    loaded: Catalog,
    failed: []u8,
    failed_static: []const u8,

    pub fn deinit(self: *ListResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .loaded => |*catalog| catalog.deinit(allocator),
            .failed => |detail| allocator.free(detail),
            .empty, .failed_static => {},
        }
        self.* = .empty;
    }
};

pub fn list(allocator: std.mem.Allocator, io: std.Io, context: command.DirectoryContext) !ListResult {
    const result = try command.runCaptured(allocator, io, context, .{
        .argv = &.{ "git", "stash", "list", "--no-color", "--encoding=UTF-8", "--format=%gd%x00%H%x00%ct%x00%gs", "-z" },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        if (result.stderr.len > 0) return .{ .failed = result.stderr };
        allocator.free(result.stderr);
        return .{ .failed_static = "Could not read Stashes; close and reopen the list" };
    }
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    return .{ .loaded = .{ .bytes = result.stdout, .entries = try parseEntries(allocator, result.stdout) } };
}

fn parseEntries(allocator: std.mem.Allocator, bytes: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);
    var remaining = bytes;
    while (remaining.len > 0) {
        var fields: [4][]const u8 = undefined;
        for (&fields) |*field| {
            const end = std.mem.indexOfScalar(u8, remaining, 0) orelse return error.InvalidStashCatalog;
            field.* = remaining[0..end];
            remaining = remaining[end + 1 ..];
        }
        const selector = fields[0];
        if (!std.mem.startsWith(u8, selector, "stash@{") or !std.mem.endsWith(u8, selector, "}") or selector.len < 9)
            return error.InvalidStashCatalog;
        const index = std.fmt.parseInt(usize, selector[7 .. selector.len - 1], 10) catch return error.InvalidStashCatalog;
        if (index != entries.items.len) return error.InvalidStashCatalog;
        if (fields[1].len != 40 and fields[1].len != 64) return error.InvalidStashCatalog;
        for (fields[1]) |c| if (!std.ascii.isHex(c)) return error.InvalidStashCatalog;
        const created = std.fmt.parseInt(i64, fields[2], 10) catch return error.InvalidStashCatalog;
        try entries.append(allocator, .{ .selector = selector, .oid = fields[1], .created = created, .message = fields[3] });
    }
    return entries.toOwnedSlice(allocator);
}

pub const ApplyRequest = struct {
    branch: ?[]const u8,
    head_oid: []const u8,
    selector: []const u8,
    stash_oid: []const u8,
};

pub const ApplyResult = struct {
    operation: operations.OperationResult,
    /// A rejected selector brings back the fresh catalog, without another read or mutation.
    refreshed_catalog: ?Catalog = null,

    pub fn deinit(self: *ApplyResult, allocator: std.mem.Allocator) void {
        self.operation.deinit(allocator);
        if (self.refreshed_catalog) |*catalog| catalog.deinit(allocator);
        self.* = undefined;
    }
};

pub fn apply(allocator: std.mem.Allocator, io: std.Io, context: command.DirectoryContext, request: ApplyRequest) !ApplyResult {
    const current = try operations.readCurrentBranchOid(allocator, io, context, request.branch) orelse
        return .{ .operation = .{ .failed_static = "Branch changed; reload and reopen Stashes" } };
    defer allocator.free(current);
    if (!std.mem.eql(u8, current, request.head_oid)) return .{ .operation = .{ .failed_static = "HEAD changed; reload and reopen Stashes" } };
    var catalog = try list(allocator, io, context);
    defer catalog.deinit(allocator);
    if (catalog != .loaded) return .{ .operation = .{ .failed_static = "Could not revalidate selected stash; reopen Stashes" } };
    const matched = for (catalog.loaded.entries) |entry| {
        if (std.mem.eql(u8, entry.selector, request.selector)) break std.mem.eql(u8, entry.oid, request.stash_oid);
    } else false;
    if (!matched) {
        const refreshed = catalog.loaded;
        catalog = .empty;
        return .{ .operation = .{ .failed_static = "Selected stash changed; list reloaded. Select again." }, .refreshed_catalog = refreshed };
    }
    // Use immutable identity after validation. Never restore the index or remove the stash.
    const result = try command.runCaptured(allocator, io, context, .{
        .argv = &.{ "git", "-c", "stash.index=false", "stash", "apply", request.stash_oid },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    if (result.term == .exited and result.term.exited == 0) {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return .{ .operation = .ok };
    }
    if (result.stderr.len > 0) {
        allocator.free(result.stdout);
        return .{ .operation = .{ .failed = result.stderr } };
    }
    allocator.free(result.stderr);
    // Merge conflicts are reported on stdout, with an unsuccessful exit status.
    if (result.stdout.len > 0) return .{ .operation = .{ .failed = result.stdout } };
    allocator.free(result.stdout);
    return .{ .operation = .{ .failed_static = "Git stash apply failed; inspect Changes for conflicts" } };
}

pub const CreateRequest = struct {
    branch: ?[]const u8,
    oid: []const u8,
    scope: Scope,
    message: []const u8,
};

pub const CreateResult = struct {
    operation: operations.OperationResult,
    /// Independent of command success: Git can save a stash before failing to clean up.
    saved_oid: ?[]u8 = null,

    pub fn deinit(self: *CreateResult, allocator: std.mem.Allocator) void {
        self.operation.deinit(allocator);
        if (self.saved_oid) |oid| allocator.free(oid);
        self.* = undefined;
    }
};

pub fn hasChanges(document: status.StatusDocument, scope: Scope) bool {
    for (document.entries) |entry| {
        if (if (scope == .staged) entry.isStaged() else !entry.isIgnored()) return true;
    }
    return false;
}

pub fn create(allocator: std.mem.Allocator, io: std.Io, context: command.DirectoryContext, request: CreateRequest) !CreateResult {
    const current_oid = try operations.readCurrentBranchOid(allocator, io, context, request.branch) orelse
        return .{ .operation = .{ .failed_static = "Branch changed; reload before creating a stash" } };
    defer allocator.free(current_oid);
    if (request.branch == null and !std.mem.eql(u8, current_oid, request.oid))
        return .{ .operation = .{ .failed_static = "Branch or HEAD changed; reload before creating a stash" } };
    var execution_request = request;
    execution_request.oid = current_oid;
    const current = try command.runCaptured(allocator, io, context, .{
        .argv = &.{ "git", "status", "--porcelain=v1", "-z", "-uall" },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer current.deinit(allocator);
    if (current.term != .exited or current.term.exited != 0)
        return .{ .operation = .{ .failed_static = "Could not revalidate stash changes" } };
    const document = try status.parse(allocator, current.stdout);
    defer allocator.free(document.entries);
    if (!hasChanges(document, request.scope))
        return .{ .operation = .{ .failed_static = "No changes in the selected stash scope" } };

    const before = try stashOid(allocator, io, context);
    defer if (before) |oid| allocator.free(oid);
    var result = CreateResult{ .operation = push(allocator, io, context, request) };
    errdefer result.deinit(allocator);
    // Always inspect after push, including runner and Git failures. Never roll back a save.
    result.saved_oid = identifySave(allocator, io, context, execution_request, before) catch {
        if (result.operation == .ok) result.operation = .{ .failed_static = "Stash command finished, but its saved stash could not be identified; inspect Stashes" };
        return result;
    };
    if (result.operation == .ok and result.saved_oid == null)
        result.operation = .{ .failed_static = "No new matching stash was identified; inspect Stashes and reload" };
    return result;
}

fn push(allocator: std.mem.Allocator, io: std.Io, context: command.DirectoryContext, request: CreateRequest) operations.OperationResult {
    const result = command.runCaptured(allocator, io, context, .{
        .argv = &.{ "git", "stash", "push", if (request.scope == .all) "--include-untracked" else "--staged", "-m", request.message },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| return .{ .failed_static = switch (err) {
        error.OutOfMemory => "Stash command could not be captured: out of memory; saved state may exist",
        error.StreamTooLong => "Stash command output exceeded its limit; saved state may exist",
        error.SpawnFailed => "Stash command execution failed; inspect the repository",
    } };
    allocator.free(result.stdout);
    if (result.term == .exited and result.term.exited == 0) {
        allocator.free(result.stderr);
        return .ok;
    }
    if (result.stderr.len > 0) return .{ .failed = result.stderr };
    allocator.free(result.stderr);
    return .{ .failed_static = "Git stash failed; inspect the repository" };
}

fn stashOid(allocator: std.mem.Allocator, io: std.Io, context: command.DirectoryContext) !?[]u8 {
    const result = try command.runCaptured(allocator, io, context, .{
        .argv = &.{ "git", "rev-parse", "--verify", "--quiet", "refs/stash" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer result.deinit(allocator);
    if (result.term != .exited) return error.StashInspectionFailed;
    if (result.term.exited == 1) return null;
    if (result.term.exited != 0) return error.StashInspectionFailed;
    const oid = std.mem.trimEnd(u8, result.stdout, "\r\n");
    if (oid.len != 40 and oid.len != 64) return error.StashInspectionFailed;
    for (oid) |c| if (!std.ascii.isHex(c)) return error.StashInspectionFailed;
    return try allocator.dupe(u8, oid);
}

fn identifySave(allocator: std.mem.Allocator, io: std.Io, context: command.DirectoryContext, request: CreateRequest, before: ?[]const u8) !?[]u8 {
    const after = try stashOid(allocator, io, context) orelse return null;
    var keep = false;
    defer if (!keep) allocator.free(after);
    if (before) |oid| if (std.mem.eql(u8, oid, after)) return null;
    const result = try command.runCaptured(allocator, io, context, .{
        // Display commands can recode the subject according to i18n.* settings.
        // Compare the exact bytes Git saved, including when commitEncoding tags them.
        .argv = &.{ "git", "cat-file", "commit", after },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer result.deinit(allocator);
    if (result.term != .exited or result.term.exited != 0) return error.StashInspectionFailed;
    const split = std.mem.indexOf(u8, result.stdout, "\n\n") orelse return error.StashInspectionFailed;
    var headers = std.mem.splitScalar(u8, result.stdout[0..split], '\n');
    const first_parent = while (headers.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) break line[7..];
    } else return null;
    if (!std.mem.eql(u8, first_parent, request.oid)) return null;
    const body = result.stdout[split + 2 ..];
    const subject = body[0 .. std.mem.indexOfScalar(u8, body, '\n') orelse body.len];
    const expected = try std.fmt.allocPrint(allocator, "On {s}: {s}", .{ request.branch orelse "(no branch)", request.message });
    defer allocator.free(expected);
    if (!std.mem.eql(u8, subject, expected)) return null;
    keep = true;
    return after;
}

const TestRepo = struct {
    tmp: std.testing.TmpDir,
    environment: command.LocalGitEnvironment,

    fn init() !TestRepo {
        var self = TestRepo{ .tmp = std.testing.tmpDir(.{}), .environment = try command.LocalGitEnvironment.initFromParent(std.testing.allocator, null) };
        errdefer self.deinit();
        try self.git(&.{ "git", "init", "--initial-branch=main" });
        try self.git(&.{ "git", "config", "user.name", "Stash Test" });
        try self.git(&.{ "git", "config", "user.email", "stash@example.invalid" });
        try self.git(&.{ "git", "config", "commit.gpgsign", "false" });
        try self.write(".gitignore", "ignored\n");
        try self.write("mixed", "one\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\nlast\n");
        try self.git(&.{ "git", "add", "." });
        try self.git(&.{ "git", "commit", "-m", "base" });
        return self;
    }

    fn deinit(self: *TestRepo) void {
        self.environment.deinit();
        self.tmp.cleanup();
    }

    fn context(self: *TestRepo) command.DirectoryContext {
        return .{ .cwd = self.tmp.dir, .environment = &self.environment };
    }

    fn write(self: *TestRepo, path: []const u8, text: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = text });
    }

    fn output(self: *TestRepo, argv: []const []const u8) ![]u8 {
        const result = try command.runCaptured(std.testing.allocator, std.testing.io, self.context(), .{ .argv = argv, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(64 * 1024) });
        defer std.testing.allocator.free(result.stderr);
        errdefer std.testing.allocator.free(result.stdout);
        try std.testing.expect(result.term == .exited and result.term.exited == 0);
        return result.stdout;
    }

    fn git(self: *TestRepo, argv: []const []const u8) !void {
        std.testing.allocator.free(try self.output(argv));
    }
};

test "stash scopes save whole worktree or staged parts of a mixed file without ignored files" {
    const allocator = std.testing.allocator;
    for ([_]Scope{ .all, .staged }) |scope| {
        var repo = try TestRepo.init();
        defer repo.deinit();
        try repo.git(&.{ "git", "config", "i18n.logOutputEncoding", "ISO-8859-1" });
        if (scope == .staged) try repo.git(&.{ "git", "config", "i18n.commitEncoding", "ISO-8859-1" });
        const head = try repo.output(&.{ "git", "rev-parse", "HEAD" });
        defer allocator.free(head);
        try repo.write("mixed", "staged\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\nlast\n");
        try repo.git(&.{ "git", "add", "mixed" });
        try repo.write("mixed", "staged\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\nunstaged\n");
        try repo.write("new", "untracked\n");
        try repo.write("ignored", "ignored\n");
        var result = try create(allocator, std.testing.io, repo.context(), .{ .branch = "main", .oid = std.mem.trimEnd(u8, head, "\n"), .scope = scope, .message = "GitFrame [main]: café q s" });
        defer result.deinit(allocator);
        try std.testing.expect(result.operation == .ok);
        try std.testing.expect(result.saved_oid != null);
        const current_oid = try repo.output(&.{ "git", "rev-parse", "refs/stash" });
        defer allocator.free(current_oid);
        try std.testing.expectEqualStrings(result.saved_oid.?, std.mem.trimEnd(u8, current_oid, "\n"));
        const parent = try repo.output(&.{ "git", "rev-parse", "refs/stash^1" });
        defer allocator.free(parent);
        try std.testing.expectEqualStrings(head, parent);
        const raw = try repo.output(&.{ "git", "cat-file", "commit", result.saved_oid.? });
        defer allocator.free(raw);
        const body_start = (std.mem.indexOf(u8, raw, "\n\n") orelse return error.TestUnexpectedResult) + 2;
        try std.testing.expectEqualStrings("On main: GitFrame [main]: café q s", std.mem.trimEnd(u8, raw[body_start..], "\n"));
        const remaining = try repo.output(&.{ "git", "status", "--porcelain=v1", "-uall" });
        defer allocator.free(remaining);
        try std.testing.expectEqualStrings(if (scope == .all) "" else " M mixed\n?? new\n", remaining);
        const ignored = try repo.tmp.dir.readFileAlloc(std.testing.io, "ignored", allocator, .limited(100));
        defer allocator.free(ignored);
        try std.testing.expectEqualStrings("ignored\n", ignored);
        const saved = try repo.output(&.{ "git", "show", "stash:mixed" });
        defer allocator.free(saved);
        try std.testing.expect(std.mem.startsWith(u8, saved, "staged\n"));
        try std.testing.expect(std.mem.endsWith(u8, saved, if (scope == .all) "unstaged\n" else "last\n"));
    }
}

test "stash allows named HEAD advance, revalidates targets and never reports an old save" {
    const allocator = std.testing.allocator;
    var repo = try TestRepo.init();
    defer repo.deinit();
    const head = try repo.output(&.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head);
    const oid = std.mem.trimEnd(u8, head, "\n");
    try repo.write("new", "new\n");
    var stale = try create(allocator, std.testing.io, repo.context(), .{ .branch = "other", .oid = oid, .scope = .all, .message = "stale" });
    defer stale.deinit(allocator);
    try std.testing.expect(stale.operation != .ok and stale.saved_oid == null);
    try std.testing.expectEqual(@as(?[]u8, null), try stashOid(allocator, std.testing.io, repo.context()));
    try repo.git(&.{ "git", "commit", "--allow-empty", "-m", "advance main" });
    const live_head = try repo.output(&.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(live_head);
    const live_oid = std.mem.trimEnd(u8, live_head, "\n");
    var advanced = try create(allocator, std.testing.io, repo.context(), .{ .branch = "main", .oid = oid, .scope = .all, .message = "advanced" });
    defer advanced.deinit(allocator);
    try std.testing.expect(advanced.operation == .ok and advanced.saved_oid != null);
    const parent = try repo.output(&.{ "git", "rev-parse", "refs/stash^1" });
    defer allocator.free(parent);
    try std.testing.expectEqualStrings(live_head, parent);
    try repo.write("new", "detached change\n");
    try repo.git(&.{ "git", "switch", "--detach", "HEAD" });
    var detached_stale = try create(allocator, std.testing.io, repo.context(), .{ .branch = null, .oid = oid, .scope = .all, .message = "stale detached" });
    defer detached_stale.deinit(allocator);
    try std.testing.expect(detached_stale.operation != .ok and detached_stale.saved_oid == null);
    const retained = (try stashOid(allocator, std.testing.io, repo.context())).?;
    defer allocator.free(retained);
    try std.testing.expectEqualStrings(advanced.saved_oid.?, retained);
    var saved = try create(allocator, std.testing.io, repo.context(), .{ .branch = null, .oid = live_oid, .scope = .all, .message = "GitFrame [detached]" });
    defer saved.deinit(allocator);
    try std.testing.expect(saved.operation == .ok and saved.saved_oid != null);
    var empty = try create(allocator, std.testing.io, repo.context(), .{ .branch = null, .oid = live_oid, .scope = .all, .message = "empty" });
    defer empty.deinit(allocator);
    try std.testing.expect(empty.operation != .ok and empty.saved_oid == null);
    const current = (try stashOid(allocator, std.testing.io, repo.context())).?;
    defer allocator.free(current);
    try std.testing.expectEqualStrings(saved.saved_oid.?, current);
}

test "stash staged cleanup failure retains the new stash and never becomes success" {
    const allocator = std.testing.allocator;
    var repo = try TestRepo.init();
    defer repo.deinit();
    try repo.git(&.{ "git", "config", "i18n.logOutputEncoding", "ISO-8859-1" });
    const head = try repo.output(&.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head);
    try repo.write("mixed", "staged replacement\n");
    try repo.git(&.{ "git", "add", "mixed" });
    try repo.write("mixed", "overlapping unstaged replacement\n");
    var result = try create(allocator, std.testing.io, repo.context(), .{ .branch = "main", .oid = std.mem.trimEnd(u8, head, "\n"), .scope = .staged, .message = "GitFrame [main]: café partial" });
    defer result.deinit(allocator);
    try std.testing.expect(result.operation != .ok);
    try std.testing.expect(result.saved_oid != null);
    const retained = (try stashOid(allocator, std.testing.io, repo.context())).?;
    defer allocator.free(retained);
    try std.testing.expectEqualStrings(result.saved_oid.?, retained);
    const saved = try repo.output(&.{ "git", "show", "stash:mixed" });
    defer allocator.free(saved);
    try std.testing.expectEqualStrings("staged replacement\n", saved);
}

test "stash list and apply pin selector identity, revalidate HEAD and disable index restoration" {
    const allocator = std.testing.allocator;
    var repo = try TestRepo.init();
    defer repo.deinit();
    const head = try repo.output(&.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head);
    try repo.write("mixed", "saved tracked\n");
    try repo.git(&.{ "git", "add", "mixed" });
    try repo.write("new", "saved untracked\n");
    try repo.git(&.{ "git", "stash", "push", "-u", "-m", "café\tmessage" });
    try repo.git(&.{ "git", "config", "stash.index", "true" });
    try repo.git(&.{ "git", "config", "log.date", "iso" });
    var catalog = try list(allocator, std.testing.io, repo.context());
    defer catalog.deinit(allocator);
    try std.testing.expect(catalog == .loaded);
    try std.testing.expectEqual(@as(usize, 1), catalog.loaded.entries.len);
    const entry = catalog.loaded.entries[0];
    try std.testing.expectEqualStrings("stash@{0}", entry.selector);
    try std.testing.expectEqualStrings("On main: café message", entry.message);
    try std.testing.expect(entry.created > 0);
    const request = ApplyRequest{ .branch = "main", .head_oid = std.mem.trimEnd(u8, head, "\n"), .selector = entry.selector, .stash_oid = entry.oid };
    var applied = try apply(allocator, std.testing.io, repo.context(), request);
    defer applied.deinit(allocator);
    try std.testing.expect(applied.operation == .ok);
    const restored = try repo.output(&.{ "git", "status", "--porcelain=v1", "-uall" });
    defer allocator.free(restored);
    try std.testing.expectEqualStrings(" M mixed\n?? new\n", restored);
    try repo.git(&.{ "git", "stash", "push", "-u", "-m", "newer stash" });
    var shifted = try apply(allocator, std.testing.io, repo.context(), request);
    defer shifted.deinit(allocator);
    try std.testing.expect(shifted.operation == .failed_static);
    try std.testing.expectEqual(@as(usize, 2), shifted.refreshed_catalog.?.entries.len);
    const clean = try repo.output(&.{ "git", "status", "--porcelain=v1", "-uall" });
    defer allocator.free(clean);
    try std.testing.expectEqualStrings("", clean);
    var updated = try list(allocator, std.testing.io, repo.context());
    defer updated.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), updated.loaded.entries.len);
    try std.testing.expectEqualStrings(entry.oid, updated.loaded.entries[1].oid);
    try repo.git(&.{ "git", "commit", "--allow-empty", "-m", "advanced" });
    var changed = request;
    changed.selector = updated.loaded.entries[0].selector;
    changed.stash_oid = updated.loaded.entries[0].oid;
    var rejected = try apply(allocator, std.testing.io, repo.context(), changed);
    defer rejected.deinit(allocator);
    try std.testing.expect(rejected.operation == .failed_static);
    const empty = try parseEntries(allocator, "");
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.InvalidStashCatalog, parseEntries(allocator, "stash@{0}\x00incomplete"));
}

test "stash apply conflict retains selected stash and actual conflicted worktree" {
    const allocator = std.testing.allocator;
    var repo = try TestRepo.init();
    defer repo.deinit();
    try repo.write("mixed", "saved version\n");
    try repo.git(&.{ "git", "stash", "push", "-m", "conflict" });
    var catalog = try list(allocator, std.testing.io, repo.context());
    defer catalog.deinit(allocator);
    const entry = catalog.loaded.entries[0];
    try repo.write("mixed", "current version\n");
    try repo.git(&.{ "git", "add", "mixed" });
    try repo.git(&.{ "git", "commit", "-m", "conflicting commit" });
    const head = try repo.output(&.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head);
    var result = try apply(allocator, std.testing.io, repo.context(), .{ .branch = "main", .head_oid = std.mem.trimEnd(u8, head, "\n"), .selector = entry.selector, .stash_oid = entry.oid });
    defer result.deinit(allocator);
    try std.testing.expect(result.operation == .failed);
    try std.testing.expect(std.mem.indexOf(u8, result.operation.failed, "CONFLICT") != null);
    const actual = try repo.output(&.{ "git", "status", "--porcelain=v1" });
    defer allocator.free(actual);
    try std.testing.expectEqualStrings("UU mixed\n", actual);
    var retained = try list(allocator, std.testing.io, repo.context());
    defer retained.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), retained.loaded.entries.len);
    try std.testing.expectEqualStrings(entry.oid, retained.loaded.entries[0].oid);
}
