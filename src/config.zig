const std = @import("std");
const keymap = @import("keymap");
const theme = @import("theme");

const max_config_bytes = 64 * 1024;
pub const supported_schema_version = 1;

pub const editor_max_argv = 16;
pub const max_external_actions = 16;
pub const max_external_action_argv = 32;

pub const Config = struct {
    schema_version: u32 = supported_schema_version,
    editor: EditorConfig = .{},
    theme: ThemeConfig = .{},
    keymap: KeymapConfig = .{},
    actions: ExternalActionsConfig = .{},
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
pub const ExternalActionsConfig = struct {
    items: [max_external_actions]ExternalActionConfig = undefined,
    len: u8 = 0,

    pub fn slice(self: *const ExternalActionsConfig) []const ExternalActionConfig {
        return self.items[0..self.len];
    }
};

pub const ExternalActionInput = enum {
    selection_context,
    review_context,
    staged_diff,
    commit_message_context,
};

pub const ExternalActionScope = enum {
    generic,
    commit,
};

pub const ExternalActionOutput = enum {
    display,
    commit_message,
};

pub const ExternalActionConfig = struct {
    id: []const u8 = "",
    label: ?[]const u8 = null,
    argv: [max_external_action_argv][]const u8 = undefined,
    argv_len: u8 = 0,
    stdin: ExternalActionInput = .selection_context,
    scope: ExternalActionScope = .generic,
    output: ExternalActionOutput = .display,

    pub fn argvSlice(self: *const ExternalActionConfig) []const []const u8 {
        return self.argv[0..self.argv_len];
    }
};

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
    InvalidBoolean,
    InvalidReloadInterval,
    InvalidString,
    InvalidArray,
    UnsupportedEscape,
    InvalidColor,
    InvalidKeyBinding,
    InvalidActionId,
    InvalidActionInput,
    InvalidActionScope,
    InvalidActionOutput,
    InvalidActionContract,
    UnknownSection,
    UnknownKey,
    TooManyArguments,
    TooManyActions,
    MissingPathPlaceholder,
    MissingActionId,
    MissingActionArgv,
    UnknownPlaceholder,
    DuplicateKey,
    DuplicateActionId,
    UnsupportedSchemaVersion,
};

fn parseConfigToml(input: []const u8) TomlParseError!Config {
    var config: Config = .{};
    var section: ConfigSection = .root;
    var action_state: ?ExternalActionParseState = null;
    var saw_empty_actions_section = false;
    var saw_actions_array = false;
    var saw_reload_auto = false;
    var saw_reload_interval = false;

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = trimTomlLine(raw_line);
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (isActionsArrayHeader(line)) {
                if (saw_empty_actions_section) return error.InvalidSection;
                try flushExternalAction(&config.actions, &action_state);
                saw_actions_array = true;
                action_state = .{};
                section = .action_entry;
            } else {
                try flushExternalAction(&config.actions, &action_state);
                section = try parseConfigSection(line);
                if (section == .actions) {
                    if (saw_actions_array) return error.InvalidSection;
                    saw_empty_actions_section = true;
                }
            }
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
            .action_entry => {
                if (action_state) |*state| {
                    try parseExternalActionField(state, key, value);
                } else {
                    return error.InvalidSection;
                }
            },
            .actions, .remote => return error.UnknownKey,
        }
    }
    try flushExternalAction(&config.actions, &action_state);

    try validateEditorConfig(config.editor);
    try validateExternalActionsConfig(config.actions);
    if (!keymap.validateConfig(config.keymap)) return error.InvalidKeyBinding;
    if (config.schema_version != supported_schema_version) return error.UnsupportedSchemaVersion;
    return config;
}

const ConfigSection = enum {
    root,
    editor,
    theme,
    keymap,
    actions,
    action_entry,
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
    if (std.mem.eql(u8, name, "actions")) return .actions;
    if (std.mem.eql(u8, name, "remote")) return .remote;
    if (std.mem.eql(u8, name, "reload")) return .reload;
    return error.UnknownSection;
}

fn parseTomlBool(value: []const u8) TomlParseError!bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}

fn isActionsArrayHeader(line: []const u8) bool {
    if (line.len < 4) return false;
    if (line[0] != '[' or line[1] != '[') return false;
    if (line[line.len - 1] != ']' or line[line.len - 2] != ']') return false;
    const name = std.mem.trim(u8, line[2 .. line.len - 2], " \t\r");
    return std.mem.eql(u8, name, "actions");
}

const ExternalActionParseState = struct {
    value: ExternalActionConfig = .{},
    seen_id: bool = false,
    seen_label: bool = false,
    seen_argv: bool = false,
    seen_stdin: bool = false,
    seen_scope: bool = false,
    seen_output: bool = false,
};

fn flushExternalAction(config: *ExternalActionsConfig, state: *?ExternalActionParseState) TomlParseError!void {
    const current = state.* orelse return;
    if (config.len >= max_external_actions) return error.TooManyActions;
    try validateExternalActionConfig(current.value, current.seen_id, current.seen_argv);

    config.items[config.len] = current.value;
    config.len += 1;
    state.* = null;
}

fn parseExternalActionField(state: *ExternalActionParseState, key: []const u8, value: []const u8) TomlParseError!void {
    if (std.mem.eql(u8, key, "id")) {
        if (state.seen_id) return error.DuplicateKey;
        const id = try parseTomlString(value);
        if (!isValidExternalActionId(id)) return error.InvalidActionId;
        state.value.id = id;
        state.seen_id = true;
    } else if (std.mem.eql(u8, key, "label")) {
        if (state.seen_label) return error.DuplicateKey;
        const label = try parseTomlString(value);
        if (label.len == 0) return error.InvalidString;
        state.value.label = label;
        state.seen_label = true;
    } else if (std.mem.eql(u8, key, "argv")) {
        if (state.seen_argv) return error.DuplicateKey;
        try parseStringArrayInto(max_external_action_argv, &state.value.argv, &state.value.argv_len, value);
        state.seen_argv = true;
    } else if (std.mem.eql(u8, key, "stdin")) {
        if (state.seen_stdin) return error.DuplicateKey;
        state.value.stdin = try parseExternalActionInput(value);
        state.seen_stdin = true;
    } else if (std.mem.eql(u8, key, "scope")) {
        if (state.seen_scope) return error.DuplicateKey;
        state.value.scope = try parseExternalActionScope(value);
        state.seen_scope = true;
    } else if (std.mem.eql(u8, key, "output")) {
        if (state.seen_output) return error.DuplicateKey;
        state.value.output = try parseExternalActionOutput(value);
        state.seen_output = true;
    } else {
        return error.UnknownKey;
    }
}

fn parseExternalActionInput(value: []const u8) TomlParseError!ExternalActionInput {
    const text = try parseTomlString(value);
    if (std.mem.eql(u8, text, "selection_context")) return .selection_context;
    if (std.mem.eql(u8, text, "review_context")) return .review_context;
    if (std.mem.eql(u8, text, "staged_diff")) return .staged_diff;
    if (std.mem.eql(u8, text, "commit_message_context")) return .commit_message_context;
    return error.InvalidActionInput;
}

fn parseExternalActionScope(value: []const u8) TomlParseError!ExternalActionScope {
    const text = try parseTomlString(value);
    if (std.mem.eql(u8, text, "commit")) return .commit;
    return error.InvalidActionScope;
}

fn parseExternalActionOutput(value: []const u8) TomlParseError!ExternalActionOutput {
    const text = try parseTomlString(value);
    if (std.mem.eql(u8, text, "display")) return .display;
    if (std.mem.eql(u8, text, "commit_message")) return .commit_message;
    return error.InvalidActionOutput;
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

fn validateExternalActionConfig(action: ExternalActionConfig, seen_id: bool, seen_argv: bool) TomlParseError!void {
    if (!seen_id) return error.MissingActionId;
    if (!seen_argv) return error.MissingActionArgv;

    // Keep the entry-level contract here even when field parsers already reject
    // the same bad values; callers that construct this type directly get the
    // same validation boundary as TOML-loaded config.
    if (!isValidExternalActionId(action.id)) return error.InvalidActionId;
    if (action.argv_len == 0) return error.MissingActionArgv;

    for (action.argvSlice()) |arg| {
        if (arg.len == 0) return error.InvalidString;
        try validateExternalActionPlaceholders(action.scope, arg);
    }

    if (!isValidExternalActionContract(action.scope, action.stdin, action.output)) return error.InvalidActionContract;
}

fn isValidExternalActionContract(scope: ExternalActionScope, stdin: ExternalActionInput, output: ExternalActionOutput) bool {
    return switch (scope) {
        .generic => switch (stdin) {
            .selection_context, .review_context => output == .display,
            .staged_diff, .commit_message_context => false,
        },
        .commit => switch (stdin) {
            .staged_diff, .commit_message_context => output == .commit_message,
            .selection_context, .review_context => false,
        },
    };
}

fn validateExternalActionsConfig(actions: ExternalActionsConfig) TomlParseError!void {
    const items = actions.slice();
    for (items, 0..) |action, i| {
        var other_index = i + 1;
        while (other_index < items.len) : (other_index += 1) {
            if (std.mem.eql(u8, action.id, items[other_index].id)) {
                return error.DuplicateActionId;
            }
        }
    }
}

fn isValidExternalActionId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (!isActionIdAlphaNum(id[0])) return false;
    for (id[1..]) |byte| {
        if (!isActionIdAlphaNum(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn isActionIdAlphaNum(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9');
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

fn validateExternalActionPlaceholders(scope: ExternalActionScope, arg: []const u8) TomlParseError!void {
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, arg, cursor, '{')) |open| {
        if (std.mem.indexOfScalarPos(u8, arg, cursor, '}')) |stray| {
            if (stray < open) return error.UnknownPlaceholder;
        }
        const close = std.mem.indexOfScalarPos(u8, arg, open + 1, '}') orelse return error.UnknownPlaceholder;
        const placeholder = arg[open .. close + 1];
        if (!isKnownPlaceholder(placeholder)) return error.UnknownPlaceholder;
        if (scope == .commit and !std.mem.eql(u8, placeholder, "{repo_root}")) return error.UnknownPlaceholder;
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
    try std.testing.expect(result.config.value.reload.auto);
    try std.testing.expectEqual(@as(u8, 3), result.config.value.reload.interval_seconds);
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
    try std.testing.expect(result.warning == null);
    try std.testing.expectEqual(@as(u8, 3), result.config.value.editor.argv_len);
    try std.testing.expectEqualStrings("nvim", result.config.value.editor.argv[0]);
    try std.testing.expectEqualStrings("+{line}", result.config.value.editor.argv[1]);
    try std.testing.expectEqualStrings("{path}", result.config.value.editor.argv[2]);
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
    try std.testing.expect(result.warning == null);
    try std.testing.expectEqual(@as(u8, 5), result.config.value.editor.argv_len);
    try std.testing.expectEqualStrings("", result.config.value.editor.argv[3]);
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
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expect(result.warning == null);
    try std.testing.expect(result.config.value.theme.get(.accent).?.toChasen().eql(.{ .index = 14 }));
    try std.testing.expect(result.config.value.theme.get(.success).?.toChasen().eql(.{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(result.config.value.theme.get(.diff_added).?.toChasen().eql(.{ .index = 10 }));
    try std.testing.expect(result.config.value.theme.get(.diff_modified).?.toChasen().eql(.{ .index = 12 }));
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
    try std.testing.expect(result.warning == null);
    try std.testing.expect(result.config.value.keymap.get(.commit).?.eql(.{ .plain_codepoint = 'm' }));
    try std.testing.expect(result.config.value.keymap.get(.repo_picker).?.eql(.{ .shifted_ascii = .{ .lower = 'o', .upper = 'O' } }));
}

test "loadConfig accepts external action definitions" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\
        \\[[actions]]
        \\id = "ai-review-selection"
        \\label = "AI review selection"
        \\argv = ["gitframe-ai-review", "--input-json", "{path}"]
        \\stdin = "selection_context"
        \\
        \\[[actions]]
        \\id = "copy_context"
        \\argv = ["cat"]
        \\stdin = "review_context"
        \\
        \\[[actions]]
        \\id = "commit-message"
        \\argv = ["helper", "{repo_root}"]
        \\stdin = "staged_diff"
        \\scope = "commit"
        \\output = "commit_message"
        \\
        \\[[actions]]
        \\id = "commit-message-improve"
        \\argv = ["helper", "--improve", "{repo_root}"]
        \\stdin = "commit_message_context"
        \\scope = "commit"
        \\output = "commit_message"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expect(result.warning == null);

    const actions = result.config.value.actions.slice();
    try std.testing.expectEqual(@as(usize, 4), actions.len);
    try std.testing.expectEqualStrings("ai-review-selection", actions[0].id);
    try std.testing.expectEqualStrings("AI review selection", actions[0].label.?);
    try std.testing.expectEqual(@as(u8, 3), actions[0].argv_len);
    try std.testing.expectEqualStrings("gitframe-ai-review", actions[0].argv[0]);
    try std.testing.expectEqualStrings("{path}", actions[0].argv[2]);
    try std.testing.expectEqual(ExternalActionInput.selection_context, actions[0].stdin);
    try std.testing.expectEqualStrings("copy_context", actions[1].id);
    try std.testing.expect(actions[1].label == null);
    try std.testing.expectEqual(ExternalActionInput.review_context, actions[1].stdin);
    try std.testing.expectEqualStrings("commit-message", actions[2].id);
    try std.testing.expectEqual(ExternalActionInput.staged_diff, actions[2].stdin);
    try std.testing.expectEqual(ExternalActionScope.commit, actions[2].scope);
    try std.testing.expectEqual(ExternalActionOutput.commit_message, actions[2].output);
    try std.testing.expectEqualStrings("commit-message-improve", actions[3].id);
    try std.testing.expectEqual(ExternalActionInput.commit_message_context, actions[3].stdin);
    try std.testing.expectEqual(ExternalActionScope.commit, actions[3].scope);
    try std.testing.expectEqual(ExternalActionOutput.commit_message, actions[3].output);
}

test "loadConfig accepts empty actions section" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-empty-section-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[actions]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expect(result.warning == null);
    try std.testing.expectEqual(@as(usize, 0), result.config.value.actions.slice().len);
}

test "loadConfig rejects mixed actions table forms" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-mixed-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[actions]
        \\
        \\[[actions]]
        \\id = "tool"
        \\argv = ["tool"]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects invalid external action ids" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-invalid-id-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[[actions]]
        \\id = "-bad"
        \\argv = ["tool"]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects duplicate external action ids" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-duplicate-id-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[[actions]]
        \\id = "tool"
        \\argv = ["tool"]
        \\
        \\[[actions]]
        \\id = "tool"
        \\argv = ["other-tool"]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects external action missing required fields" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-missing-required-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[[actions]]
        \\label = "No argv"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects external action missing id" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-missing-id-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[[actions]]
        \\argv = ["tool"]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects invalid external action argv" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-invalid-argv-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[[actions]]
        \\id = "tool"
        \\argv = ["tool", ""]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects too many external actions" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-too-many-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[[actions]]
        \\id = "tool0"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool1"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool2"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool3"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool4"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool5"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool6"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool7"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool8"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool9"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool10"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool11"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool12"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool13"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool14"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool15"
        \\argv = ["tool"]
        \\[[actions]]
        \\id = "tool16"
        \\argv = ["tool"]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects too many external action argv items" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-too-many-argv-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[[actions]]
        \\id = "tool"
        \\argv = ["a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "a10", "a11", "a12", "a13", "a14", "a15", "a16", "a17", "a18", "a19", "a20", "a21", "a22", "a23", "a24", "a25", "a26", "a27", "a28", "a29", "a30", "a31", "a32"]
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects unknown external action stdin values" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-unknown-stdin-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[[actions]]
        \\id = "tool"
        \\argv = ["tool"]
        \\stdin = "everything"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects invalid external action scope and output" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-invalid-scope-output-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[[actions]]
        \\id = "tool"
        \\argv = ["tool"]
        \\scope = "selection"
        \\output = "commit_message"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects commit action target placeholders" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-commit-placeholder-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[[actions]]
        \\id = "commit-message"
        \\argv = ["helper", "{path}"]
        \\stdin = "staged_diff"
        \\scope = "commit"
        \\output = "commit_message"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects commit message context outside commit scope" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-commit-context-generic-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[[actions]]
        \\id = "commit-message-improve"
        \\argv = ["helper"]
        \\stdin = "commit_message_context"
        \\output = "display"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loadConfig rejects unknown external action keys" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-actions-unknown-key-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[[actions]]
        \\id = "tool"
        \\argv = ["tool"]
        \\command = "tool"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
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
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}

test "loaded theme config feeds palette derivation" {
    const allocator = std.testing.allocator;
    const path = "zig-cache/tmp/gitframe-theme-derived-config.toml";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "zig-cache/tmp");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\schema_version = 1
        \\[theme]
        \\success = "#010203"
        \\info = "#070809"
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var result = loadConfig(allocator, std.testing.io, path);
    defer result.deinit();
    try std.testing.expect(result.warning == null);

    const palette = theme.Palette.fromConfig(result.config.value.theme);
    try std.testing.expect(palette.color(.success).eql(.{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(palette.color(.diff_added).eql(.{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(palette.color(.diff_modified).eql(.{ .rgb = .{ 7, 8, 9 } }));
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
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
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
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
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
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
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
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
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
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
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
    try std.testing.expectEqual(LoadWarning.invalid_toml, result.warning.?);
}
