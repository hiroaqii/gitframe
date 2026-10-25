const std = @import("std");
const keymap = @import("keymap");
const theme = @import("theme");

const max_config_bytes = 64 * 1024;
pub const supported_schema_version = 1;

pub const editor_max_argv = 16;

pub const Config = struct {
    schema_version: u32 = supported_schema_version,
    editor: EditorConfig = .{},
    theme: ThemeConfig = .{},
    keymap: KeymapConfig = .{},
    remote: RemoteWorkflowConfig = .{},
    reload: ReloadConfig = .{},
};

pub const ReloadConfig = struct {
    auto: bool = true,
    interval_seconds: u8 = 3,
};

pub const State = struct {
    schema_version: u32 = supported_schema_version,
    recent_repositories: RecentRepositoriesState = .{},
};

pub const EditorConfig = struct {
    argv: [editor_max_argv][]const u8 = undefined,
    argv_len: u8 = 0,

    pub fn argvSlice(self: *const EditorConfig) []const []const u8 {
        return self.argv[0..self.argv_len];
    }
};
pub const ThemeConfig = struct {
    overrides: [theme.role_count]?theme.ColorValue = [_]?theme.ColorValue{null} ** theme.role_count,

    pub fn set(self: *ThemeConfig, role: theme.Role, value: theme.ColorValue) void {
        self.overrides[@intFromEnum(role)] = value;
    }

    pub fn get(self: ThemeConfig, role: theme.Role) ?theme.ColorValue {
        return self.overrides[@intFromEnum(role)];
    }
};
pub const KeymapConfig = keymap.Config;
pub const RemoteWorkflowConfig = struct {
    // Remote workflow config may hold policy/command preferences, but never
    // credentials. Tokens and passphrases must stay in credential helpers,
    // agents, environment, keychains, or foreground prompts.
};

pub const RecentRepositoryKind = enum {
    repo,
    workspace,
};

pub const RecentRepositoryEntry = struct {
    kind: RecentRepositoryKind,
    path: []const u8,
};

pub const RecentRepositoriesState = struct {
    entries: []const RecentRepositoryEntry = &.{},
};

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
    invalid_json,
    unsupported_schema_version,
    read_failed,
};

pub const ConfigLoadFailure = union(enum) {
    read_failed,
    read_permission_denied,
    read_is_directory,
    read_too_large,
    invalid_toml,
    unsupported_schema_version,
};

pub const LoadConfigResult = union(enum) {
    success: OwnedConfig,
    failure: ConfigLoadFailure,

    pub fn deinit(self: *LoadConfigResult) void {
        switch (self.*) {
            .success => |*config| config.deinit(),
            .failure => {},
        }
        self.* = undefined;
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
    const config_path = try joinConfigPath(allocator, xdg_config_home, home);
    errdefer if (config_path) |path| allocator.free(path);
    return .{
        .config = config_path,
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
    const file_path = path orelse return .{ .success = .{} };
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(max_config_bytes)) catch |err| {
        return switch (err) {
            error.FileNotFound => .{ .success = .{} },
            else => .{ .failure = classifyConfigReadError(err) },
        };
    };
    const config = parseConfigToml(bytes) catch |err| {
        allocator.free(bytes);
        return .{ .failure = classifyConfigParseError(err) };
    };

    return .{ .success = .{
        .value = config,
        .source_bytes = bytes,
        .allocator = allocator,
    } };
}

fn classifyConfigReadError(err: anyerror) ConfigLoadFailure {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .read_permission_denied,
        error.IsDir => .read_is_directory,
        error.StreamTooLong, error.FileTooBig => .read_too_large,
        else => .read_failed,
    };
}

fn classifyConfigParseError(err: TomlParseError) ConfigLoadFailure {
    return switch (err) {
        error.UnsupportedSchemaVersion => .unsupported_schema_version,
        else => .invalid_toml,
    };
}

const TomlParseError = error{
    InvalidLine,
    InvalidSection,
    InvalidKeyValue,
    InvalidInteger,
    InvalidBoolean,
    InvalidReloadInterval,
    InvalidString,
    InvalidArray,
    UnsupportedEscape,
    InvalidColor,
    InvalidKeyBinding,
    UnknownSection,
    UnknownKey,
    TooManyArguments,
    MissingPathPlaceholder,
    UnknownPlaceholder,
    DuplicateKey,
    UnsupportedSchemaVersion,
};

fn parseConfigToml(input: []const u8) TomlParseError!Config {
    var config: Config = .{};
    var section: ConfigSection = .root;
    var saw_reload_auto = false;
    var saw_reload_interval = false;

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
            // Section names are reserved so later settings can grow under a
            // stable TOML shape. Empty sections remain valid.
            .editor => {
                if (!std.mem.eql(u8, key, "argv")) return error.UnknownKey;
                config.editor = try parseEditorArgv(value);
            },
            .theme => {
                const role = theme.roleFromKey(key) orelse return error.UnknownKey;
                config.theme.set(role, try parseThemeColor(value));
            },
            .keymap => {
                const action = keymap.actionFromKey(key) orelse return error.UnknownKey;
                const spec_text = try parseTomlString(value);
                const spec = keymap.parseKeySpec(spec_text) orelse return error.InvalidKeyBinding;
                config.keymap.set(action, spec);
            },
            .reload => {
                if (std.mem.eql(u8, key, "auto")) {
                    if (saw_reload_auto) return error.DuplicateKey;
                    config.reload.auto = try parseTomlBool(value);
                    saw_reload_auto = true;
                } else if (std.mem.eql(u8, key, "interval_seconds")) {
                    if (saw_reload_interval) return error.DuplicateKey;
                    const interval = std.fmt.parseInt(u8, value, 10) catch return error.InvalidInteger;
                    if (interval < 1 or interval > 60) return error.InvalidReloadInterval;
                    config.reload.interval_seconds = interval;
                    saw_reload_interval = true;
                } else {
                    return error.UnknownKey;
                }
            },
            .remote => return error.UnknownKey,
        }
    }

    try validateEditorConfig(config.editor);
    if (!keymap.validateConfig(config.keymap)) return error.InvalidKeyBinding;
    if (config.schema_version != supported_schema_version) return error.UnsupportedSchemaVersion;
    return config;
}

const ConfigSection = enum {
    root,
    editor,
    theme,
    keymap,
    remote,
    reload,
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
    if (std.mem.eql(u8, name, "remote")) return .remote;
    if (std.mem.eql(u8, name, "reload")) return .reload;
    return error.UnknownSection;
}

fn parseTomlBool(value: []const u8) TomlParseError!bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}

fn parseEditorArgv(value: []const u8) TomlParseError!EditorConfig {
    var config: EditorConfig = .{};
    try parseStringArrayInto(editor_max_argv, &config.argv, &config.argv_len, value);
    return config;
}

fn parseStringArrayInto(
    comptime max_len: usize,
    output: *[max_len][]const u8,
    len: *u8,
    value: []const u8,
) TomlParseError!void {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return error.InvalidArray;
    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t\r");
    if (inner.len == 0) return error.InvalidArray;

    var index: usize = 0;
    while (index < inner.len) {
        if (@as(usize, len.*) >= max_len) return error.TooManyArguments;

        while (index < inner.len and isTomlSpace(inner[index])) : (index += 1) {}
        if (index >= inner.len) break;
        if (inner[index] != '"') return error.InvalidString;

        const start = index;
        index += 1;
        while (index < inner.len and inner[index] != '"') : (index += 1) {
            if (inner[index] == '\\') return error.UnsupportedEscape;
        }
        if (index >= inner.len) return error.InvalidString;
        const token = inner[start + 1 .. index];
        index += 1;

        output[@as(usize, len.*)] = token;
        len.* += 1;

        while (index < inner.len and isTomlSpace(inner[index])) : (index += 1) {}
        if (index == inner.len) break;
        if (inner[index] != ',') return error.InvalidArray;
        index += 1;
    }

    if (len.* == 0) return error.InvalidArray;
}

fn validateEditorConfig(editor: EditorConfig) TomlParseError!void {
    if (editor.argv_len == 0) return;

    const argv = editor.argvSlice();
    if (argv[0].len == 0) return error.InvalidString;

    var has_path = false;
    for (argv) |arg| {
        if (std.mem.indexOf(u8, arg, "{path}") != null) has_path = true;
        try validatePlaceholders(arg);
    }
    if (!has_path) return error.MissingPathPlaceholder;
}

fn parseThemeColor(value: []const u8) TomlParseError!theme.ColorValue {
    const color_text = try parseTomlString(value);
    return theme.parseColorValue(color_text) orelse error.InvalidColor;
}

fn parseTomlString(value: []const u8) TomlParseError![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidString;
    const inner = value[1 .. value.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') != null) return error.UnsupportedEscape;
    if (std.mem.indexOfScalar(u8, inner, '"') != null) return error.InvalidString;
    return inner;
}

fn validatePlaceholders(arg: []const u8) TomlParseError!void {
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, arg, cursor, '{')) |open| {
        if (std.mem.indexOfScalarPos(u8, arg, cursor, '}')) |stray| {
            if (stray < open) return error.UnknownPlaceholder;
        }
        const close = std.mem.indexOfScalarPos(u8, arg, open + 1, '}') orelse return error.UnknownPlaceholder;
        const placeholder = arg[open .. close + 1];
        if (!isKnownPlaceholder(placeholder)) return error.UnknownPlaceholder;
        cursor = close + 1;
    }
    if (std.mem.indexOfScalarPos(u8, arg, cursor, '}') != null) return error.UnknownPlaceholder;
}

fn isKnownPlaceholder(value: []const u8) bool {
    return std.mem.eql(u8, value, "{path}") or
        std.mem.eql(u8, value, "{line}") or
        std.mem.eql(u8, value, "{column}") or
        std.mem.eql(u8, value, "{repo_root}");
}

fn isTomlSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
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

test "resolvePaths releases partial paths on allocation failure" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var paths = try resolvePathsFromValues(allocator, "/xdg/config", "/xdg/state", null);
            defer paths.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "loadConfig uses defaults when path is missing" {
    var result = loadConfig(std.testing.allocator, std.testing.io, null);
    defer result.deinit();

    const loaded = switch (result) {
        .success => |*config| config,
        .failure => return error.ExpectedConfigSuccess,
    };
    try std.testing.expectEqual(@as(u32, supported_schema_version), loaded.value.schema_version);
    try std.testing.expect(loaded.source_bytes == null);
}

test "loadConfig uses defaults when file is missing" {
    var result = loadConfig(std.testing.allocator, std.testing.io, "zig-cache/tmp/gitframe-missing-config.toml");
    defer result.deinit();

    const loaded = switch (result) {
        .success => |*config| config,
        .failure => return error.ExpectedConfigSuccess,
    };
    try std.testing.expectEqual(@as(u32, supported_schema_version), loaded.value.schema_version);
    try std.testing.expect(loaded.source_bytes == null);
}

test "loadConfig fails when an existing config path cannot be read" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const failure = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedConfigFailure,
    };
    try std.testing.expectEqual(ConfigLoadFailure.read_is_directory, failure);
}

test "config read errors preserve actionable failure reasons" {
    try std.testing.expectEqual(
        ConfigLoadFailure.read_permission_denied,
        classifyConfigReadError(error.AccessDenied),
    );
    try std.testing.expectEqual(
        ConfigLoadFailure.read_permission_denied,
        classifyConfigReadError(error.PermissionDenied),
    );
    try std.testing.expectEqual(
        ConfigLoadFailure.read_is_directory,
        classifyConfigReadError(error.IsDir),
    );
    try std.testing.expectEqual(
        ConfigLoadFailure.read_too_large,
        classifyConfigReadError(error.StreamTooLong),
    );
    try std.testing.expectEqual(
        ConfigLoadFailure.read_too_large,
        classifyConfigReadError(error.FileTooBig),
    );
    try std.testing.expectEqual(
        ConfigLoadFailure.read_failed,
        classifyConfigReadError(error.Unexpected),
    );
}

test "loadConfig rejects config files at the size limit" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-oversized-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    var contents: [max_config_bytes]u8 = undefined;
    @memset(contents[0..], ' ');
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = contents[0..] });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const failure = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedConfigFailure,
    };
    try std.testing.expectEqual(ConfigLoadFailure.read_too_large, failure);
}

test "loadConfig fails for invalid toml without a config payload" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-invalid-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "{ invalid" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const failure = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedConfigFailure,
    };
    try std.testing.expectEqual(ConfigLoadFailure.invalid_toml, failure);
}

test "loadConfig rejects unknown fields" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-unknown-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "unknown = true\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const failure = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedConfigFailure,
    };
    try std.testing.expectEqual(ConfigLoadFailure.invalid_toml, failure);
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

test "loadConfig fails for unsupported schema version without a config payload" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-schema-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "schema_version = 999\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const failure = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedConfigFailure,
    };
    try std.testing.expectEqual(ConfigLoadFailure.unsupported_schema_version, failure);
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
        \\[remote]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const loaded = switch (result) {
        .success => |*config| config,
        .failure => return error.ExpectedConfigSuccess,
    };
    try std.testing.expectEqual(@as(u32, supported_schema_version), loaded.value.schema_version);
    try std.testing.expect(loaded.value.reload.auto);
    try std.testing.expectEqual(@as(u8, 3), loaded.value.reload.interval_seconds);
    try std.testing.expect(loaded.source_bytes != null);
}

test "parse config accepts reload policy" {
    const parsed = try parseConfigToml(
        \\schema_version = 1
        \\[reload]
        \\auto = false
        \\interval_seconds = 1
        \\
    );
    try std.testing.expect(!parsed.reload.auto);
    try std.testing.expectEqual(@as(u8, 1), parsed.reload.interval_seconds);

    const upper = try parseConfigToml(
        \\[reload]
        \\interval_seconds = 60
        \\
    );
    try std.testing.expectEqual(@as(u8, 60), upper.reload.interval_seconds);
}

test "parse config rejects invalid reload policy" {
    try std.testing.expectError(error.InvalidReloadInterval, parseConfigToml(
        \\[reload]
        \\interval_seconds = 0
        \\
    ));
    try std.testing.expectError(error.InvalidReloadInterval, parseConfigToml(
        \\[reload]
        \\interval_seconds = 61
        \\
    ));
    try std.testing.expectError(error.InvalidBoolean, parseConfigToml(
        \\[reload]
        \\auto = "yes"
        \\
    ));
    try std.testing.expectError(error.DuplicateKey, parseConfigToml(
        \\[reload]
        \\auto = true
        \\auto = false
        \\
    ));
}

test "loadConfig accepts editor argv template" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-editor-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[editor]
        \\argv = ["nvim", "+{line}", "{path}"]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const loaded = switch (result) {
        .success => |*config| config,
        .failure => return error.ExpectedConfigSuccess,
    };
    try std.testing.expectEqual(@as(u8, 3), loaded.value.editor.argv_len);
    try std.testing.expectEqualStrings("nvim", loaded.value.editor.argv[0]);
    try std.testing.expectEqualStrings("+{line}", loaded.value.editor.argv[1]);
    try std.testing.expectEqualStrings("{path}", loaded.value.editor.argv[2]);
}

test "loadConfig accepts editor argv empty non-command argument" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-editor-empty-arg-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[editor]
        \\argv = ["sh", "-c", "exec nvim", "", "{path}"]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const loaded = switch (result) {
        .success => |*config| config,
        .failure => return error.ExpectedConfigSuccess,
    };
    try std.testing.expectEqual(@as(u8, 5), loaded.value.editor.argv_len);
    try std.testing.expectEqualStrings("", loaded.value.editor.argv[3]);
}

test "loadConfig accepts theme color overrides" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-theme-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[theme]
        \\accent = "bright-cyan"
        \\success = "#010203"
        \\diff_added = "index:10"
        \\diff_modified = "index:12"
        \\pane_cursor_bg = "#292a2b"
        \\pane_active_line_number = "#ffdaaa"
        \\diff_selection_bg = "#304052"
        \\syntax_keyword = "#111213"
        \\syntax_operator = "bright-cyan"
        \\syntax_function = "index:12"
        \\syntax_property = "#212223"
        \\syntax_type = "bright-yellow"
        \\syntax_constant = "index:13"
        \\syntax_string = "#313233"
        \\syntax_number = "bright-red"
        \\syntax_comment = "index:8"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const loaded = switch (result) {
        .success => |*config| config,
        .failure => return error.ExpectedConfigSuccess,
    };
    try std.testing.expect(loaded.value.theme.get(.accent).?.toChasen().eql(.{ .index = 14 }));
    try std.testing.expect(loaded.value.theme.get(.success).?.toChasen().eql(.{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(loaded.value.theme.get(.diff_added).?.toChasen().eql(.{ .index = 10 }));
    try std.testing.expect(loaded.value.theme.get(.diff_modified).?.toChasen().eql(.{ .index = 12 }));
    try std.testing.expect(loaded.value.theme.get(.pane_cursor_bg).?.toChasen().eql(.{ .rgb = .{ 41, 42, 43 } }));
    try std.testing.expect(loaded.value.theme.get(.pane_active_line_number).?.toChasen().eql(.{ .rgb = .{ 255, 218, 170 } }));
    try std.testing.expect(loaded.value.theme.get(.diff_selection_bg).?.toChasen().eql(.{ .rgb = .{ 48, 64, 82 } }));
    try std.testing.expect(loaded.value.theme.get(.syntax_keyword).?.toChasen().eql(.{ .rgb = .{ 17, 18, 19 } }));
    try std.testing.expect(loaded.value.theme.get(.syntax_operator).?.toChasen().eql(.{ .index = 14 }));
    try std.testing.expect(loaded.value.theme.get(.syntax_function).?.toChasen().eql(.{ .index = 12 }));
    try std.testing.expect(loaded.value.theme.get(.syntax_property).?.toChasen().eql(.{ .rgb = .{ 33, 34, 35 } }));
    try std.testing.expect(loaded.value.theme.get(.syntax_type).?.toChasen().eql(.{ .index = 11 }));
    try std.testing.expect(loaded.value.theme.get(.syntax_constant).?.toChasen().eql(.{ .index = 13 }));
    try std.testing.expect(loaded.value.theme.get(.syntax_string).?.toChasen().eql(.{ .rgb = .{ 49, 50, 51 } }));
    try std.testing.expect(loaded.value.theme.get(.syntax_number).?.toChasen().eql(.{ .index = 9 }));
    try std.testing.expect(loaded.value.theme.get(.syntax_comment).?.toChasen().eql(.{ .index = 8 }));
}

test "parse config accepts every syntax role in each color form" {
    const roles = [_]theme.Role{
        .syntax_keyword,
        .syntax_operator,
        .syntax_function,
        .syntax_property,
        .syntax_type,
        .syntax_constant,
        .syntax_string,
        .syntax_number,
        .syntax_comment,
    };
    const cases = [_]struct {
        text: []const u8,
        expected: theme.ColorValue,
    }{
        .{ .text = "#010203", .expected = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } },
        .{ .text = "bright-cyan", .expected = .{ .named = .bright_cyan } },
        .{ .text = "index:12", .expected = .{ .index = 12 } },
    };

    for (roles) |role| {
        for (cases) |case| {
            const input = try std.fmt.allocPrint(std.testing.allocator,
                \\[theme]
                \\{s} = "{s}"
                \\
            , .{ @tagName(role), case.text });
            defer std.testing.allocator.free(input);
            const config = try parseConfigToml(input);
            try std.testing.expect(config.theme.get(role).?.toChasen().eql(case.expected.toChasen()));
        }
    }
}

test "parse config rejects removed repository cursor theme key" {
    try std.testing.expectError(error.UnknownKey, parseConfigToml(
        \\[theme]
        \\repository_cursor_bg = "#2d303a"
        \\
    ));
}

test "parse config rejects removed repository active line number theme key" {
    try std.testing.expectError(error.UnknownKey, parseConfigToml(
        \\[theme]
        \\repository_active_line_number = "#ffdaaa"
        \\
    ));
}

test "loadConfig accepts keymap overrides" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-keymap-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[keymap]
        \\commit = "m"
        \\repo_picker = "O"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const loaded = switch (result) {
        .success => |*config| config,
        .failure => return error.ExpectedConfigSuccess,
    };
    try std.testing.expect(loaded.value.keymap.get(.commit).?.eql(.{ .plain_codepoint = 'm' }));
    try std.testing.expect(loaded.value.keymap.get(.repo_picker).?.eql(.{ .shifted_ascii = .{ .lower = 'o', .upper = 'O' } }));
}

test "keymap accepts History and Compare pages" {
    const parsed = try parseConfigToml(
        \\schema_version = 1
        \\[keymap]
        \\page_history = "3"
        \\page_compare = "4"
        \\copy_history_detail = "x"
    );
    try std.testing.expect(parsed.keymap.get(.page_history).?.eql(.{ .plain_codepoint = '3' }));
    try std.testing.expect(parsed.keymap.get(.page_compare).?.eql(.{ .plain_codepoint = '4' }));
    try std.testing.expect(parsed.keymap.get(.copy_history_detail).?.eql(.{ .plain_codepoint = 'x' }));
}

test "keymap rejects removed file edges and accepts document navigation actions" {
    inline for (.{ "first_file", "last_file" }) |removed| {
        const input = try std.fmt.allocPrint(std.testing.allocator,
            \\schema_version = 1
            \\[keymap]
            \\{s} = "z"
        , .{removed});
        defer std.testing.allocator.free(input);
        try std.testing.expectError(error.UnknownKey, parseConfigToml(input));
    }

    const parsed = try parseConfigToml(
        \\schema_version = 1
        \\[keymap]
        \\document_first = "g"
        \\document_last = "G"
        \\half_page_up = "ctrl+u"
        \\half_page_down = "ctrl+d"
        \\page_backward = "ctrl+b"
        \\page_forward = "ctrl+f"
        \\previous_file = "["
        \\next_file = "]"
        \\decrease_sidebar_width = "<"
        \\increase_sidebar_width = ">"
    );
    try std.testing.expect(parsed.keymap.get(.document_first).?.eql(.{ .plain_codepoint = 'g' }));
    try std.testing.expect(parsed.keymap.get(.document_last).?.eql(.{ .shifted_ascii = .{ .lower = 'g', .upper = 'G' } }));
    try std.testing.expect(parsed.keymap.get(.half_page_up).?.eql(.{ .ctrl = .u }));
    try std.testing.expect(parsed.keymap.get(.half_page_down).?.eql(.{ .ctrl = .d }));
    try std.testing.expect(parsed.keymap.get(.page_backward).?.eql(.{ .ctrl = .b }));
    try std.testing.expect(parsed.keymap.get(.page_forward).?.eql(.{ .ctrl = .f }));
    try std.testing.expect(parsed.keymap.get(.previous_file).?.eql(.{ .plain_codepoint = '[' }));
    try std.testing.expect(parsed.keymap.get(.next_file).?.eql(.{ .plain_codepoint = ']' }));
    try std.testing.expect(keymap.validateConfig(parsed.keymap));
}

test "loadConfig rejects invalid keymap overrides" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-keymap-invalid-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[keymap]
        \\commit = "s"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const failure = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedConfigFailure,
    };
    try std.testing.expectEqual(ConfigLoadFailure.invalid_toml, failure);
}

test "loaded theme config feeds palette derivation" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-theme-derived-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[theme]
        \\accent = "#0a0b0c"
        \\success = "#010203"
        \\info = "#070809"
        \\history_date = "#141516"
        \\syntax_string = "index:13"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const loaded = switch (result) {
        .success => |*config| config,
        .failure => return error.ExpectedConfigSuccess,
    };

    const palette = theme.Palette.fromConfig(loaded.value.theme);
    try std.testing.expect(palette.color(.success).eql(.{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(palette.color(.diff_added).eql(.{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(palette.color(.diff_modified).eql(.{ .rgb = .{ 7, 8, 9 } }));
    try std.testing.expect(palette.color(.syntax_keyword).eql(.{ .rgb = .{ 10, 11, 12 } }));
    try std.testing.expect(palette.color(.syntax_operator).eql(.{ .rgb = .{ 10, 11, 12 } }));
    try std.testing.expect(palette.color(.syntax_function).eql(.{ .rgb = .{ 7, 8, 9 } }));
    try std.testing.expect(palette.color(.syntax_property).eql(.{ .rgb = .{ 7, 8, 9 } }));
    try std.testing.expect(palette.color(.history_date).eql(.{ .rgb = .{ 20, 21, 22 } }));
    try std.testing.expect(palette.color(.syntax_string).eql(.{ .index = 13 }));
}

test "loadConfig rejects unknown theme keys" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-theme-unknown-key-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[theme]
        \\diff-added = "green"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const failure = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedConfigFailure,
    };
    try std.testing.expectEqual(ConfigLoadFailure.invalid_toml, failure);
}

test "loadConfig rejects invalid theme color values" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-theme-invalid-color-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[theme]
        \\accent = "not-a-color"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const failure = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedConfigFailure,
    };
    try std.testing.expectEqual(ConfigLoadFailure.invalid_toml, failure);
}

test "loadConfig rejects editor argv without path placeholder" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-editor-missing-path-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[editor]
        \\argv = ["nvim", "+{line}"]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const failure = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedConfigFailure,
    };
    try std.testing.expectEqual(ConfigLoadFailure.invalid_toml, failure);
}

test "loadConfig rejects unknown editor placeholders" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-editor-unknown-placeholder-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[editor]
        \\argv = ["nvim", "{path}", "{unknown}"]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const failure = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedConfigFailure,
    };
    try std.testing.expectEqual(ConfigLoadFailure.invalid_toml, failure);
}

test "loadConfig rejects stray editor placeholder closing brace" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-editor-stray-placeholder-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[editor]
        \\argv = ["nvim", "}{path}", "{path}"]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const failure = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedConfigFailure,
    };
    try std.testing.expectEqual(ConfigLoadFailure.invalid_toml, failure);
}

test "loadConfig rejects empty editor command" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-editor-empty-command-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[editor]
        \\argv = ["", "{path}"]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    const failure = switch (result) {
        .failure => |value| value,
        .success => return error.ExpectedConfigFailure,
    };
    try std.testing.expectEqual(ConfigLoadFailure.invalid_toml, failure);
}
