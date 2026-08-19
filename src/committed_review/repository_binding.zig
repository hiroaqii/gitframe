const std = @import("std");
const identity = @import("identity.zig");

pub const ReviewRepositoryId = identity.ReviewRepositoryId;

pub const GitCommonDirectoryLocator = struct {
    device: u64,
    inode: u64,

    pub fn eql(self: GitCommonDirectoryLocator, other: GitCommonDirectoryLocator) bool {
        return self.device == other.device and self.inode == other.inode;
    }
};

pub const RepositoryBindingResult = union(enum) {
    bound: ReviewRepositoryId,
    unbound,
    registry_invalid,
    registry_unavailable,
};

pub const RepositoryBindingRegistry = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resolve: *const fn (context: *anyopaque, locator: GitCommonDirectoryLocator) RepositoryBindingResult,
    };

    pub fn resolve(self: RepositoryBindingRegistry, locator: GitCommonDirectoryLocator) RepositoryBindingResult {
        const result = self.vtable.resolve(self.context, locator);
        return switch (result) {
            .bound => |repository_id| validateRepositoryId(repository_id),
            .unbound => .unbound,
            .registry_invalid => .registry_invalid,
            .registry_unavailable => .registry_unavailable,
        };
    }
};

fn validateRepositoryId(repository_id: ReviewRepositoryId) RepositoryBindingResult {
    const canonical = repository_id.canonical();
    _ = ReviewRepositoryId.parse(&canonical) catch return .registry_invalid;
    return .{ .bound = repository_id };
}

test "repository binding registry resolves seeded physical locators and fails closed" {
    const Mapping = struct {
        locator: GitCommonDirectoryLocator,
        repository_id: ReviewRepositoryId,
    };
    const FakeRegistry = struct {
        mappings: []const Mapping,
        forced_terminal: ?RepositoryBindingResult = null,

        fn from(context: *anyopaque) *@This() {
            return @ptrCast(@alignCast(context));
        }

        fn resolve(context: *anyopaque, locator: GitCommonDirectoryLocator) RepositoryBindingResult {
            const self = from(context);
            if (self.forced_terminal) |terminal| return terminal;
            for (self.mappings) |mapping| {
                if (mapping.locator.eql(locator)) return .{ .bound = mapping.repository_id };
            }
            return .unbound;
        }

        const vtable: RepositoryBindingRegistry.VTable = .{ .resolve = resolve };

        fn interface(self: *@This()) RepositoryBindingRegistry {
            return .{ .context = self, .vtable = &vtable };
        }
    };

    const first_locator: GitCommonDirectoryLocator = .{ .device = 7, .inode = 11 };
    const second_locator: GitCommonDirectoryLocator = .{ .device = 7, .inode = 12 };
    const unknown_locator: GitCommonDirectoryLocator = .{ .device = 8, .inode = 11 };
    const first_id = try ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const second_id = try ReviewRepositoryId.parse("223e4567-e89b-42d3-a456-426614174000");
    const mappings = [_]Mapping{
        .{ .locator = first_locator, .repository_id = first_id },
        .{ .locator = second_locator, .repository_id = second_id },
    };
    var registry = FakeRegistry{ .mappings = &mappings };
    const binding = registry.interface();

    try std.testing.expect(binding.resolve(first_locator).bound.eql(first_id));
    try std.testing.expect(binding.resolve(second_locator).bound.eql(second_id));
    try std.testing.expect(binding.resolve(unknown_locator) == .unbound);

    var invalid = FakeRegistry{ .mappings = &mappings, .forced_terminal = .registry_invalid };
    try std.testing.expect(invalid.interface().resolve(first_locator) == .registry_invalid);
    var malformed = FakeRegistry{
        .mappings = &mappings,
        .forced_terminal = .{ .bound = .{ .bytes = [_]u8{0} ** 16 } },
    };
    try std.testing.expect(malformed.interface().resolve(first_locator) == .registry_invalid);
    var unavailable = FakeRegistry{ .mappings = &mappings, .forced_terminal = .registry_unavailable };
    try std.testing.expect(unavailable.interface().resolve(first_locator) == .registry_unavailable);
}

test "physical locator stores only device and inode" {
    const fields = std.meta.fields(GitCommonDirectoryLocator);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("device", fields[0].name);
    try std.testing.expectEqualStrings("inode", fields[1].name);
    try std.testing.expect(!@hasDecl(GitCommonDirectoryLocator, "canonical"));
    try std.testing.expect(!@hasDecl(GitCommonDirectoryLocator, "parse"));
}
