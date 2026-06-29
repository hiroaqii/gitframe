const std = @import("std");

const max_config_bytes = 64 * 1024;
const supported_schema_version = 1;

pub const Config = struct {
    schema_version: u32 = supported_schema_version,
    editor: EditorConfig = .{},
    theme: ThemeConfig = .{},
    keymap: KeymapConfig = .{},
    actions: ExternalActionsConfig = .{},
    remote: RemoteWorkflowConfig = .{},
};

pub const State = struct {
    schema_version: u32 = supported_schema_version,
    recent_repositories: RecentRepositoriesState = .{},
};

pub const EditorConfig = struct {};
pub const ThemeConfig = struct {};
pub const KeymapConfig = struct {};
pub const ExternalActionsConfig = struct {};

pub const RemoteWorkflowConfig = struct {
    // Remote workflow config may hold policy/command preferences, but never
    // credentials. Tokens and passphrases must stay in credential helpers,
    // agents, environment, keychains, or foreground prompts.
};

pub const RecentRepositoriesState = struct {};

pub const Paths = struct {
    config: ?[]u8 = null,
    state: ?[]u8 = null,

    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        if (self.config) |path| allocator.free(path);
        if (self.state) |path| allocator.free(path);
        self.* = .{};
    }
};

pub const LoadWarning = enum {
    invalid_toml,
    invalid_json,
    unsupported_schema_version,
    read_failed,
};

pub const LoadConfigResult = struct {
    config: OwnedConfig = .{},
    warning: ?LoadWarning = null,

    pub fn deinit(self: *LoadConfigResult) void {
        self.config.deinit();
        self.* = .{};
    }
};

pub const LoadStateResult = struct {
    state: OwnedState = .{},
    warning: ?LoadWarning = null,

    pub fn deinit(self: *LoadStateResult) void {
        self.state.deinit();
        self.* = .{};
    }
};

pub const OwnedState = OwnedJson(State);

pub const OwnedConfig = struct {
    value: Config = .{},
    source_bytes: ?[]u8 = null,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *OwnedConfig) void {
        if (self.source_bytes) |bytes| {
            if (self.allocator) |allocator| allocator.free(bytes);
        }
        self.* = .{};
    }
};

fn OwnedJson(comptime T: type) type {
    return struct {
        value: T = .{},
        parsed: ?std.json.Parsed(T) = null,

        pub fn deinit(self: *@This()) void {
            if (self.parsed) |parsed| parsed.deinit();
            self.* = .{};
        }
    };
}

pub fn resolvePaths(allocator: std.mem.Allocator, env: ?*std.process.Environ.Map) !Paths {
    return resolvePathsFromValues(
        allocator,
        envValue(env, "XDG_CONFIG_HOME"),
        envValue(env, "XDG_STATE_HOME"),
        envValue(env, "HOME"),
    );
}

pub fn resolvePathsFromValues(
    allocator: std.mem.Allocator,
    xdg_config_home: ?[]const u8,
    xdg_state_home: ?[]const u8,
    home: ?[]const u8,
) !Paths {
    return .{
        .config = try joinConfigPath(allocator, xdg_config_home, home),
        .state = try joinStatePath(allocator, xdg_state_home, home),
    };
}

pub fn loadConfig(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) LoadConfigResult {
    return loadTomlConfig(allocator, io, path);
}

pub fn loadState(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) LoadStateResult {
    const parsed = loadJson(State, allocator, io, path, .{
        .ignore_unknown_fields = true,
    });
    return .{
        .state = parsed.data,
        .warning = parsed.warning,
    };
}

fn envValue(env: ?*std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const map = env orelse return null;
    const value = map.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

fn joinConfigPath(allocator: std.mem.Allocator, xdg_config_home: ?[]const u8, home: ?[]const u8) !?[]u8 {
    if (xdg_config_home) |root| {
        return try std.fs.path.join(allocator, &.{ root, "gitframe", "config.toml" });
    }
    const home_path = home orelse return null;
    return try std.fs.path.join(allocator, &.{ home_path, ".config", "gitframe", "config.toml" });
}

fn joinStatePath(allocator: std.mem.Allocator, xdg_state_home: ?[]const u8, home: ?[]const u8) !?[]u8 {
    if (xdg_state_home) |root| {
        return try std.fs.path.join(allocator, &.{ root, "gitframe", "state.json" });
    }
    const home_path = home orelse return null;
    return try std.fs.path.join(allocator, &.{ home_path, ".local", "state", "gitframe", "state.json" });
}

const JsonLoadOptions = struct {
    ignore_unknown_fields: bool,
};

fn JsonLoadResult(comptime T: type) type {
    return struct {
        data: OwnedJson(T) = .{},
        warning: ?LoadWarning = null,
    };
}

fn loadTomlConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: ?[]const u8,
) LoadConfigResult {
    const file_path = path orelse return .{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(max_config_bytes)) catch |err| {
        return .{ .warning = switch (err) {
            error.FileNotFound => null,
            else => .read_failed,
        } };
    };
    const config = parseConfigToml(bytes) catch |err| {
        allocator.free(bytes);
        return .{ .warning = switch (err) {
            error.UnsupportedSchemaVersion => .unsupported_schema_version,
            else => .invalid_toml,
        } };
    };

    return .{ .config = .{
        .value = config,
        .source_bytes = bytes,
        .allocator = allocator,
    } };
}

const TomlParseError = error{
    InvalidLine,
    InvalidSection,
    InvalidKeyValue,
    InvalidInteger,
    UnknownSection,
    UnknownKey,
    UnsupportedSchemaVersion,
};

fn parseConfigToml(input: []const u8) TomlParseError!Config {
    var config: Config = .{};
    var section: ConfigSection = .root;

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = trimTomlLine(raw_line);
        if (line.len == 0) continue;

        if (line[0] == '[') {
            section = try parseConfigSection(line);
            continue;
        }

        const separator_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidKeyValue;
        const key = std.mem.trim(u8, line[0..separator_index], " \t\r");
        const value = std.mem.trim(u8, line[separator_index + 1 ..], " \t\r");
        if (key.len == 0 or value.len == 0) return error.InvalidKeyValue;

        switch (section) {
            .root => {
                if (!std.mem.eql(u8, key, "schema_version")) return error.UnknownKey;
                config.schema_version = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInteger;
            },
            // Section names are reserved now so later settings can grow under a
            // stable TOML shape. Empty sections are valid in the foundation slice.
            .editor, .theme, .keymap, .actions, .remote => return error.UnknownKey,
        }
    }

    if (config.schema_version != supported_schema_version) return error.UnsupportedSchemaVersion;
    return config;
}

const ConfigSection = enum {
    root,
    editor,
    theme,
    keymap,
    actions,
    remote,
};

fn trimTomlLine(line: []const u8) []const u8 {
    const without_cr = std.mem.trim(u8, line, "\r");
    const comment_index = tomlCommentStart(without_cr);
    return std.mem.trim(u8, without_cr[0..comment_index], " \t\r");
}

fn tomlCommentStart(line: []const u8) usize {
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '"' => in_string = !in_string,
            '#' => if (!in_string) return i,
            else => {},
        }
    }
    return line.len;
}

fn parseConfigSection(line: []const u8) TomlParseError!ConfigSection {
    if (line.len < 3 or line[line.len - 1] != ']') return error.InvalidSection;
    const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t\r");
    if (std.mem.eql(u8, name, "editor")) return .editor;
    if (std.mem.eql(u8, name, "theme")) return .theme;
    if (std.mem.eql(u8, name, "keymap")) return .keymap;
    if (std.mem.eql(u8, name, "actions")) return .actions;
    if (std.mem.eql(u8, name, "remote")) return .remote;
    return error.UnknownSection;
}

fn loadJson(
    comptime T: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: ?[]const u8,
    options: JsonLoadOptions,
) JsonLoadResult(T) {
    const file_path = path orelse return .{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(max_config_bytes)) catch |err| {
        return .{ .warning = switch (err) {
            error.FileNotFound => null,
            else => .read_failed,
        } };
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(T, allocator, bytes, .{
        // State values must live with OwnedState, not with this temporary input buffer.
        .allocate = .alloc_always,
        .ignore_unknown_fields = options.ignore_unknown_fields,
    }) catch return .{ .warning = .invalid_json };

    if (parsed.value.schema_version != supported_schema_version) {
        parsed.deinit();
        return .{ .warning = .unsupported_schema_version };
    }

    return .{ .data = .{
        .value = parsed.value,
        .parsed = parsed,
    } };
}

test "resolvePaths uses XDG locations when present" {
    const allocator = std.testing.allocator;
    var paths = try resolvePathsFromValues(allocator, "/xdg/config", "/xdg/state", "/home/tester");
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("/xdg/config/gitframe/config.toml", paths.config.?);
    try std.testing.expectEqualStrings("/xdg/state/gitframe/state.json", paths.state.?);
}

test "resolvePaths falls back to HOME locations" {
    const allocator = std.testing.allocator;
    var paths = try resolvePathsFromValues(allocator, null, null, "/home/tester");
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("/home/tester/.config/gitframe/config.toml", paths.config.?);
    try std.testing.expectEqualStrings("/home/tester/.local/state/gitframe/state.json", paths.state.?);
}

test "resolvePaths returns null paths when HOME and XDG are missing" {
    const allocator = std.testing.allocator;
    var paths = try resolvePathsFromValues(allocator, null, null, null);
    defer paths.deinit(allocator);

    try std.testing.expect(paths.config == null);
    try std.testing.expect(paths.state == null);
}

test "loadConfig uses defaults when path is missing" {
    var result = loadConfig(std.testing.allocator, std.testing.io, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, supported_schema_version), result.config.value.schema_version);
    try std.testing.expect(result.warning == null);
}

test "loadConfig uses defaults when file is missing" {
    var result = loadConfig(std.testing.allocator, std.testing.io, "zig-cache/tmp/gitframe-missing-config.toml");
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, supported_schema_version), result.config.value.schema_version);
    try std.testing.expect(result.warning == null);
}

test "loadConfig warns for invalid toml" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-invalid-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "{ invalid" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects unknown fields" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-unknown-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "unknown = true\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadState ignores unknown fields" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-state.json";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "{\"unknown\":true}" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadState(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expect(result.warning == null);
    try std.testing.expectEqual(@as(u32, supported_schema_version), result.state.value.schema_version);
}

test "loadConfig warns for unsupported schema version" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-schema-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "schema_version = 999\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.unsupported_schema_version, result.warning.?);
}

test "loadConfig accepts reserved empty TOML sections" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-empty-sections-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[editor]
        \\[theme]
        \\[keymap]
        \\[actions]
        \\[remote]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expect(result.warning == null);
    try std.testing.expectEqual(@as(u32, supported_schema_version), result.config.value.schema_version);
}
