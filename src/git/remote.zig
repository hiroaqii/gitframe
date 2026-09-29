const std = @import("std");
const builtin = @import("builtin");
const git_push = @import("push.zig");
const git_command = @import("command.zig");
const git_ref = @import("ref.zig");
const git_branch_status = @import("branch_status.zig");
const process_runner = @import("../process/runner.zig");
const root_capability = @import("../repo/root_capability.zig");

pub const RemoteEnvironmentMode = enum {
    background,
    inspection,
    foreground,
    local_finalizer,
};

pub const RemoteWarningSet = packed struct {
    git_plaintext_store: bool = false,
    gcm_plaintext_store: bool = false,
    potential_plaintext_store: bool = false,
    helper_policy_unknown: bool = false,
    proxy_credentials_omitted: bool = false,

    pub fn merge(self: *RemoteWarningSet, other: RemoteWarningSet) void {
        self.git_plaintext_store = self.git_plaintext_store or other.git_plaintext_store;
        self.gcm_plaintext_store = self.gcm_plaintext_store or other.gcm_plaintext_store;
        self.potential_plaintext_store = self.potential_plaintext_store or other.potential_plaintext_store;
        self.helper_policy_unknown = self.helper_policy_unknown or other.helper_policy_unknown;
        self.proxy_credentials_omitted = self.proxy_credentials_omitted or other.proxy_credentials_omitted;
    }
};

pub const OwnedRemoteEnvironment = struct {
    map: std.process.Environ.Map,
    warnings: RemoteWarningSet = .{},

    pub fn deinit(self: *OwnedRemoteEnvironment) void {
        self.map.deinit();
        self.* = undefined;
    }
};

/// App-safe terminal vocabulary for a background remote operation. Raw child
/// output is deliberately absent: the backend classifies it while it is held
/// by SensitiveBytes and destroys it before returning across this boundary.
pub const RemoteFailure = enum {
    authentication_required,
    ssh_public_key,
    http_userinfo_rejected,
    canceled,
    timed_out,
    outcome_unknown,
    canceled_outcome_unknown,
    timed_out_outcome_unknown,
    spawn_failed,
    failed,
};

pub const RemoteSuccess = enum {
    completed,
    already_up_to_date,
    push_tracking_incomplete,
};

pub const RemoteOperationOutcome = union(enum) {
    ok: RemoteSuccess,
    failed: RemoteFailure,
};

pub const RemoteOperationResult = struct {
    outcome: RemoteOperationOutcome,
    warnings: RemoteWarningSet = .{},
};

pub const RemoteOperationKind = union(enum) {
    push: PushRequest,
    pull_refresh_ff_only: PullRequest,
    fetch: FetchRequest,
};

/// Descriptor-bound authority for one background remote operation.
///
/// `root` and `environment` are borrowed for the synchronous call. The App
/// task owns both values for its entire run. `control.deadline` is one absolute
/// timestamp shared by URL/config preflight, snapshot verification, and every
/// network or merge child.
pub const RemoteOperationRequest = struct {
    root: *const root_capability.RootCapability,
    environment: *const OwnedRemoteEnvironment,
    control: process_runner.ProcessControl,
    kind: RemoteOperationKind,
};

pub const ForegroundPushInspectionOutcome = union(enum) {
    ready,
    branch_changed,
    oid_changed,
    failed: RemoteFailure,
};

pub const ForegroundPushInspectionResult = struct {
    outcome: ForegroundPushInspectionOutcome,
    warnings: RemoteWarningSet = .{},
};

/// Descriptor-bound, raw-free admission result for a native foreground push.
/// The audit and snapshot verification run in one task immediately before the
/// App queues the terminal child; no URL or config bytes cross this boundary.
pub const ForegroundPushInspectionRequest = struct {
    root: *const root_capability.RootCapability,
    environment: *const OwnedRemoteEnvironment,
    control: process_runner.ProcessControl,
    push: PushRequest,
};

pub const PushUpstreamFinalizeOutcome = enum {
    configured,
    already_configured,
    context_changed,
    branch_changed,
    oid_changed,
    upstream_conflict,
    config_write_failed,
    config_verification_failed,
    tracking_unknown,
};

/// One local-only finalization attempt after a fixed-OID native push has
/// already succeeded. Every child uses the retained descriptor and strict
/// replacement environment supplied by the owning task.
pub const PushUpstreamFinalizeRequest = struct {
    root: *const root_capability.RootCapability,
    environment: *const OwnedRemoteEnvironment,
    control: process_runner.ProcessControl,
    branch: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
    oid: []const u8,
};

pub const PushRequest = struct {
    mode: git_push.Mode = .upstream,
    branch: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
    /// Commit snapshot used by the pre-push safety check and as the immutable
    /// source refspec in both background and foreground pushes.
    oid: []const u8,
};

/// Owned foreground command inputs prepared by the remote domain.
///
/// `argv` points only at static strings and the two owned buffers below. The
/// caller may pass it, `environment.map`, and its retained root descriptor to
/// Chasen while this value is alive; Chasen copies all three inputs before its
/// queue call returns.
pub const PreparedForegroundPush = struct {
    argv: [13][]const u8,
    remote: []u8,
    refspec: []u8,
    environment: OwnedRemoteEnvironment,

    pub fn deinit(self: *PreparedForegroundPush, allocator: std.mem.Allocator) void {
        self.environment.deinit();
        allocator.free(self.refspec);
        allocator.free(self.remote);
        self.* = undefined;
    }
};

pub const PullRequest = struct {
    upstream_ref: []const u8,
    branch: []const u8,
    remote: []const u8,
    remote_branch: []const u8,
    /// Commit snapshot used by the pre-pull safety check. Pull mutates the
    /// current branch, so the backend must fail closed if the confirmation was
    /// approved for an older HEAD.
    oid: []const u8,
};

pub const FetchRequest = struct {
    remote: []const u8,
};

/// Runs the credentialless background remote path. This is the sole remote
/// entry point that executes background push, pull, or fetch: it accepts a
/// retained root descriptor and returns no child-owned diagnostic bytes.
pub fn runOperation(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: RemoteOperationRequest,
) RemoteOperationResult {
    return runSecureRemoteOperation(allocator, io, request);
}

pub fn inspectForegroundPush(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: ForegroundPushInspectionRequest,
) ForegroundPushInspectionResult {
    return runForegroundPushInspection(allocator, io, request);
}

pub fn finalizePushUpstream(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
) PushUpstreamFinalizeOutcome {
    return runPushUpstreamFinalizer(allocator, io, request);
}

fn termExited(term: std.process.Child.Term, expected: u8) bool {
    return switch (term) {
        .exited => |code| code == expected,
        else => false,
    };
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn trimLineEnd(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\r\n");
}

const RevListAheadBehind = struct {
    ahead: u32,
    behind: u32,
};

fn parseRevListAheadBehind(text: []const u8) git_command.Error!RevListAheadBehind {
    var iter = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const ahead_text = iter.next() orelse return error.SpawnFailed;
    const behind_text = iter.next() orelse return error.SpawnFailed;
    return .{
        .ahead = std.fmt.parseInt(u32, ahead_text, 10) catch return error.SpawnFailed,
        .behind = std.fmt.parseInt(u32, behind_text, 10) catch return error.SpawnFailed,
    };
}

const max_remote_diagnostic_bytes = 256 * 1024;

const SensitiveRemoteCommand = union(enum) {
    completed: process_runner.SensitiveResult,
    canceled: process_runner.SpawnPhase,
    timed_out: process_runner.SpawnPhase,
    failed: process_runner.ControlledFailure,

    fn deinit(self: *SensitiveRemoteCommand) void {
        switch (self.*) {
            .completed => |*result| result.deinit(),
            .canceled, .timed_out, .failed => {},
        }
        self.* = .{ .failed = .empty_argv };
    }
};

const RemoteUrlUse = enum { fetch, push };
const UrlAudit = enum { accepted, userinfo, invalid };
const RemoteCheck = union(enum) {
    matches,
    mismatch,
    failed: RemoteFailure,
};

fn runSecureRemoteOperation(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: RemoteOperationRequest,
) RemoteOperationResult {
    var warnings = request.environment.warnings;
    var uses_http_remote = false;
    const remote_and_use: struct { remote: []const u8, use: RemoteUrlUse } = switch (request.kind) {
        .push => |push| .{ .remote = push.remote, .use = .push },
        .pull_refresh_ff_only => |pull| .{ .remote = pull.remote, .use = .fetch },
        .fetch => |fetch| .{ .remote = fetch.remote, .use = .fetch },
    };

    if (auditRemoteUrls(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        remote_and_use.remote,
        remote_and_use.use,
        &uses_http_remote,
    )) |failure| return remoteFailureResult(failure, warnings);

    if (classifyCredentialPolicy(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        &warnings,
    )) |failure| return remoteFailureResult(failure, warnings);
    filterCredentialWarningsForRemote(&warnings, uses_http_remote);

    return switch (request.kind) {
        .push => |push| runSecureGitPush(allocator, io, request, push, warnings),
        .pull_refresh_ff_only => |pull| runSecureGitPull(allocator, io, request, pull, warnings),
        .fetch => |fetch| runSecureGitFetch(allocator, io, request, fetch, warnings),
    };
}

fn remoteFailureResult(failure: RemoteFailure, warnings: RemoteWarningSet) RemoteOperationResult {
    return .{ .outcome = .{ .failed = failure }, .warnings = warnings };
}

fn remoteSuccessResult(success: RemoteSuccess, warnings: RemoteWarningSet) RemoteOperationResult {
    return .{ .outcome = .{ .ok = success }, .warnings = warnings };
}

fn runSensitiveRemoteCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
    argv: []const []const u8,
) SensitiveRemoteCommand {
    const controlled = process_runner.runCapturedControlled(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .environ_map = environment,
        .stdout_limit = .limited(max_remote_diagnostic_bytes),
        .stderr_limit = .limited(max_remote_diagnostic_bytes),
    }, .sensitive, control);
    return switch (controlled) {
        .completed => |captured| switch (captured) {
            .sensitive => |result| .{ .completed = result },
            .ordinary => unreachable,
        },
        .canceled => |phase| .{ .canceled = phase },
        .timed_out => |phase| .{ .timed_out = phase },
        .failed => |failure| .{ .failed = failure },
    };
}

fn commandExited(command: *const SensitiveRemoteCommand, expected_code: u8) bool {
    return switch (command.*) {
        .completed => |result| switch (result.term) {
            .exited => |code| code == expected_code,
            else => false,
        },
        .canceled, .timed_out, .failed => false,
    };
}

/// after_update retains earlier effects even if this particular child never starts.
const CommandPhase = enum { read_only, may_update, after_update };

fn commandFailure(command: *const SensitiveRemoteCommand, diagnose: bool, phase: CommandPhase) ?RemoteFailure {
    return switch (command.*) {
        .canceled => |spawn| if (phase == .after_update or (phase == .may_update and spawn == .started))
            .canceled_outcome_unknown
        else
            .canceled,
        .timed_out => |spawn| if (phase == .after_update or (phase == .may_update and spawn == .started))
            .timed_out_outcome_unknown
        else
            .timed_out,
        .failed => |failure| switch (failure) {
            .spawn => if (phase == .after_update) .outcome_unknown else .spawn_failed,
            .empty_argv, .unsupported_process_control => if (phase == .after_update) .outcome_unknown else .failed,
            else => if (phase == .read_only) .failed else .outcome_unknown,
        },
        .completed => |result| switch (result.term) {
            .exited => |code| if (code == 0)
                null
            else if (diagnose)
                diagnoseRemoteFailure(result.stdout.bytes(), result.stderr.bytes())
            else
                .failed,
            else => if (phase == .read_only) .failed else .outcome_unknown,
        },
    };
}

fn diagnoseRemoteFailure(stdout: []const u8, stderr: []const u8) RemoteFailure {
    const public_key_patterns = [_][]const u8{
        "permission denied (publickey",
        "no supported authentication methods available",
    };
    for (public_key_patterns) |pattern| {
        if (indexOfIgnoreCase(stdout, pattern) != null or indexOfIgnoreCase(stderr, pattern) != null)
            return .ssh_public_key;
    }

    const authentication_patterns = [_][]const u8{
        "authentication failed",
        "authentication required",
        "could not read username",
        "terminal prompts disabled",
        "http 401",
        "returned error: 401",
        "access denied",
    };
    for (authentication_patterns) |pattern| {
        if (indexOfIgnoreCase(stdout, pattern) != null or indexOfIgnoreCase(stderr, pattern) != null)
            return .authentication_required;
    }
    return .failed;
}

fn auditRemoteUrls(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
    remote: []const u8,
    use: RemoteUrlUse,
    uses_http_remote: *bool,
) ?RemoteFailure {
    uses_http_remote.* = false;
    const effective_argv = switch (use) {
        .fetch => &[_][]const u8{ "git", "remote", "get-url", "--all", "--", remote },
        .push => &[_][]const u8{ "git", "remote", "get-url", "--push", "--all", "--", remote },
    };
    var effective = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, effective_argv);
    defer effective.deinit();
    if (commandFailure(&effective, false, .read_only)) |failure| return failure;
    const effective_bytes = switch (effective) {
        .completed => |*result| result.stdout.bytes(),
        else => unreachable,
    };
    switch (auditLineFramedUrls(effective_bytes)) {
        .accepted => {},
        .userinfo => return .http_userinfo_rejected,
        .invalid => return .failed,
    }
    uses_http_remote.* = lineFramedUrlsUseHttp(effective_bytes);

    const url_key = std.fmt.allocPrint(allocator, "remote.{s}.url", .{remote}) catch return .failed;
    defer allocator.free(url_key);
    if (auditConfigUrlValues(allocator, io, cwd, environment, control, url_key, false)) |failure| return failure;

    const pushurl_key = std.fmt.allocPrint(allocator, "remote.{s}.pushurl", .{remote}) catch return .failed;
    defer allocator.free(pushurl_key);
    if (auditConfigUrlValues(allocator, io, cwd, environment, control, pushurl_key, true)) |failure| return failure;
    return null;
}

fn auditConfigUrlValues(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
    key: []const u8,
    optional: bool,
) ?RemoteFailure {
    const argv = [_][]const u8{ "git", "config", "--null", "--get-all", key };
    var command = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &argv);
    defer command.deinit();
    if (optional and commandExited(&command, 1)) return null;
    if (commandFailure(&command, false, .read_only)) |failure| return failure;
    const bytes = switch (command) {
        .completed => |*result| result.stdout.bytes(),
        else => unreachable,
    };
    switch (auditNulFramedUrls(bytes)) {
        .accepted => return null,
        .userinfo => return .http_userinfo_rejected,
        .invalid => return .failed,
    }
}

fn auditLineFramedUrls(bytes: []const u8) UrlAudit {
    if (bytes.len == 0 or std.mem.indexOfScalar(u8, bytes, 0) != null) return .invalid;
    var count: usize = 0;
    var start: usize = 0;
    while (start < bytes.len) {
        const relative_end = std.mem.indexOfScalar(u8, bytes[start..], '\n');
        const end = if (relative_end) |offset| start + offset else bytes.len;
        const line = bytes[start..end];
        if (line.len == 0 or std.mem.indexOfScalar(u8, line, '\r') != null) return .invalid;
        count += 1;
        switch (auditRemoteUrlValue(line)) {
            .accepted => {},
            .userinfo => return .userinfo,
            .invalid => return .invalid,
        }
        start = if (relative_end == null) bytes.len else end + 1;
    }
    return if (count > 0) .accepted else .invalid;
}

fn lineFramedUrlsUseHttp(bytes: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |url| {
        if (std.ascii.startsWithIgnoreCase(url, "http://") or
            std.ascii.startsWithIgnoreCase(url, "https://")) return true;
    }
    return false;
}

fn auditNulFramedUrls(bytes: []const u8) UrlAudit {
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return .invalid;
    var count: usize = 0;
    var start: usize = 0;
    while (start < bytes.len) {
        const relative_end = std.mem.indexOfScalar(u8, bytes[start..], 0) orelse return .invalid;
        const end = start + relative_end;
        const value = bytes[start..end];
        if (value.len == 0 or std.mem.indexOfAny(u8, value, "\r\n") != null) return .invalid;
        count += 1;
        switch (auditRemoteUrlValue(value)) {
            .accepted => {},
            .userinfo => return .userinfo,
            .invalid => return .invalid,
        }
        start = end + 1;
    }
    return if (count > 0) .accepted else .invalid;
}

fn auditRemoteUrlValue(url: []const u8) UrlAudit {
    for (url) |byte| if (byte < 0x20 or byte == 0x7f) return .invalid;
    const scheme_len: usize = if (std.ascii.startsWithIgnoreCase(url, "http://"))
        "http://".len
    else if (std.ascii.startsWithIgnoreCase(url, "https://"))
        "https://".len
    else
        return .accepted;
    const uri = std.Uri.parse(url) catch return .invalid;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or uri.host == null)
        return .invalid;
    const authority = url[scheme_len .. std.mem.indexOfAnyPos(u8, url, scheme_len, "/?#") orelse url.len];
    if (uri.user != null or uri.password != null or std.mem.indexOfScalar(u8, authority, '@') != null)
        return .userinfo;
    return .accepted;
}

fn classifyCredentialPolicy(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
    warnings: *RemoteWarningSet,
) ?RemoteFailure {
    const helper_argv = [_][]const u8{ "git", "config", "--null", "--get-all", "credential.helper" };
    var helpers = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &helper_argv);
    defer helpers.deinit();
    if (!commandExited(&helpers, 1)) {
        if (commandFailure(&helpers, false, .read_only)) |failure| return failure;
        const bytes = switch (helpers) {
            .completed => |*result| result.stdout.bytes(),
            else => unreachable,
        };
        if (!classifyHelperRecords(bytes, warnings)) return .failed;
    }

    const origin_argv = [_][]const u8{ "git", "config", "--show-origin", "--null", "--get-all", "credential.helper" };
    var origins = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &origin_argv);
    defer origins.deinit();
    if (!commandExited(&origins, 1)) {
        if (commandFailure(&origins, false, .read_only)) |failure| return failure;
        const bytes = switch (origins) {
            .completed => |*result| result.stdout.bytes(),
            else => unreachable,
        };
        if (!classifyHelperOrigins(bytes, warnings)) return .failed;
    }

    const scoped_argv = [_][]const u8{ "git", "config", "--null", "--get-regexp", "^credential\\..*\\.helper$" };
    var scoped = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &scoped_argv);
    defer scoped.deinit();
    if (!commandExited(&scoped, 1)) {
        if (commandFailure(&scoped, false, .read_only)) |failure| return failure;
        const bytes = switch (scoped) {
            .completed => |*result| result.stdout.bytes(),
            else => unreachable,
        };
        if (!classifyScopedHelperRecords(bytes, warnings)) return .failed;
    }

    const store_argv = [_][]const u8{ "git", "config", "--null", "--get", "credential.credentialStore" };
    var store = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &store_argv);
    defer store.deinit();
    if (!commandExited(&store, 1)) {
        if (commandFailure(&store, false, .read_only)) |failure| return failure;
        const bytes = switch (store) {
            .completed => |*result| result.stdout.bytes(),
            else => unreachable,
        };
        if (nulSingleValueEquals(bytes, "plaintext")) warnings.gcm_plaintext_store = true;
    }
    if (environment.get("GCM_CREDENTIAL_STORE")) |value| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), "plaintext"))
            warnings.gcm_plaintext_store = true;
    }
    return null;
}

fn filterCredentialWarningsForRemote(warnings: *RemoteWarningSet, uses_http_remote: bool) void {
    // An unclassified helper is not involved in a non-HTTP Git transport.
    // Keep positive plaintext detections visible regardless of transport.
    if (!uses_http_remote) warnings.helper_policy_unknown = false;
}

fn classifyHelperRecords(bytes: []const u8, warnings: *RemoteWarningSet) bool {
    if (bytes.len == 0) return true;
    if (bytes[bytes.len - 1] != 0) return false;
    var plaintext_active = false;
    var unknown_active = false;
    var start: usize = 0;
    while (start < bytes.len) {
        const relative_end = std.mem.indexOfScalar(u8, bytes[start..], 0) orelse return false;
        const end = start + relative_end;
        const value = std.mem.trim(u8, bytes[start..end], " \t");
        if (value.len == 0) {
            plaintext_active = false;
            unknown_active = false;
        } else if (helperIsPlaintextStore(value)) {
            plaintext_active = true;
        } else if (!helperIsKnownNonPlaintext(value)) {
            unknown_active = true;
        }
        start = end + 1;
    }
    if (plaintext_active) warnings.git_plaintext_store = true;
    if (unknown_active) warnings.helper_policy_unknown = true;
    return true;
}

fn classifyHelperOrigins(bytes: []const u8, warnings: *RemoteWarningSet) bool {
    if (bytes.len == 0) return true;
    if (bytes[bytes.len - 1] != 0) return false;
    var start: usize = 0;
    while (start < bytes.len) {
        const origin_end_offset = std.mem.indexOfScalar(u8, bytes[start..], 0) orelse return false;
        const origin_end = start + origin_end_offset;
        const origin = bytes[start..origin_end];
        start = origin_end + 1;
        if (start >= bytes.len) return false;
        const value_end_offset = std.mem.indexOfScalar(u8, bytes[start..], 0) orelse return false;
        const value = std.mem.trim(u8, bytes[start .. start + value_end_offset], " \t");
        start += value_end_offset + 1;
        if (!std.mem.startsWith(u8, origin, "file:.git/config")) {
            if (helperIsPlaintextStore(value)) {
                warnings.potential_plaintext_store = true;
            } else if (value.len > 0 and !helperIsKnownNonPlaintext(value)) {
                warnings.helper_policy_unknown = true;
            }
        }
    }
    return true;
}

fn classifyScopedHelperRecords(bytes: []const u8, warnings: *RemoteWarningSet) bool {
    if (bytes.len == 0) return true;
    if (bytes[bytes.len - 1] != 0) return false;
    var start: usize = 0;
    while (start < bytes.len) {
        const end_offset = std.mem.indexOfScalar(u8, bytes[start..], 0) orelse return false;
        const end = start + end_offset;
        const record = bytes[start..end];
        const separator = std.mem.indexOfScalar(u8, record, '\n') orelse return false;
        if (separator == 0) return false;
        const value = std.mem.trim(u8, record[separator + 1 ..], " \t");
        if (helperIsPlaintextStore(value)) {
            warnings.potential_plaintext_store = true;
        } else if (value.len > 0 and !helperIsKnownNonPlaintext(value)) {
            warnings.helper_policy_unknown = true;
        }
        start = end + 1;
    }
    return true;
}

fn helperIsPlaintextStore(value: []const u8) bool {
    const token = helperCommandToken(value) orelse return false;
    if (std.ascii.eqlIgnoreCase(token, "store")) return true;
    const base = std.fs.path.basename(token);
    return std.ascii.eqlIgnoreCase(base, "git-credential-store");
}

fn helperIsKnownNonPlaintext(value: []const u8) bool {
    const token = helperCommandToken(value) orelse return false;
    const base = std.fs.path.basename(token);
    const known = [_][]const u8{ "cache", "manager", "manager-core", "libsecret", "osxkeychain", "wincred", "oauth" };
    for (known) |candidate| {
        if (std.ascii.eqlIgnoreCase(token, candidate) or
            std.ascii.eqlIgnoreCase(base, candidate) or
            (std.mem.startsWith(u8, base, "git-credential-") and
                std.ascii.eqlIgnoreCase(base["git-credential-".len..], candidate))) return true;
    }
    return false;
}

fn helperCommandToken(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0 or trimmed[0] == '!' or trimmed[0] == '\'' or trimmed[0] == '"') return null;
    for (trimmed) |byte| if (byte < 0x20 and byte != '\t') return null;
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..end];
}

fn nulSingleValueEquals(bytes: []const u8, expected: []const u8) bool {
    if (bytes.len == 0) return false;
    const value = if (bytes[bytes.len - 1] == 0) bytes[0 .. bytes.len - 1] else bytes;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), expected);
}

fn runForegroundPushInspection(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: ForegroundPushInspectionRequest,
) ForegroundPushInspectionResult {
    var warnings = request.environment.warnings;
    var uses_http_remote = false;
    if (auditRemoteUrls(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        request.push.remote,
        .push,
        &uses_http_remote,
    )) |failure| return .{ .outcome = .{ .failed = failure }, .warnings = warnings };
    if (classifyCredentialPolicy(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        &warnings,
    )) |failure| return .{ .outcome = .{ .failed = failure }, .warnings = warnings };
    filterCredentialWarningsForRemote(&warnings, uses_http_remote);

    const refs = validatePushRefNames(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        request.push.branch,
        request.push.remote_branch,
    );
    switch (refs) {
        .valid => {},
        .invalid => return .{ .outcome = .branch_changed, .warnings = warnings },
        .failed => |failure| return .{ .outcome = .{ .failed = failure }, .warnings = warnings },
    }

    return .{
        .outcome = switch (inspectCurrentBranchAndOid(
            allocator,
            io,
            request.root.dir(),
            &request.environment.map,
            request.control,
            request.push.branch,
            request.push.oid,
        )) {
            .matches => .ready,
            .context_changed, .branch_changed => .branch_changed,
            .oid_changed => .oid_changed,
            .failed => |failure| .{ .failed = failure },
        },
        .warnings = warnings,
    };
}

const RefValidation = union(enum) {
    valid,
    invalid,
    failed: RemoteFailure,
};

fn validatePushRefNames(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
    branch: []const u8,
    remote_branch: []const u8,
) RefValidation {
    const branch_argv = [_][]const u8{ "git", "check-ref-format", "--branch", branch };
    var branch_command = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &branch_argv);
    defer branch_command.deinit();
    switch (sensitiveExitCode(&branch_command, .read_only)) {
        .code => |code| if (code != 0) return .invalid,
        .failure => |failure| return .{ .failed = failure },
    }

    const remote_ref = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{remote_branch}) catch
        return .{ .failed = .failed };
    defer allocator.free(remote_ref);
    const remote_argv = [_][]const u8{ "git", "check-ref-format", remote_ref };
    var remote_command = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &remote_argv);
    defer remote_command.deinit();
    return switch (sensitiveExitCode(&remote_command, .read_only)) {
        .code => |code| if (code == 0) .valid else .invalid,
        .failure => |failure| .{ .failed = failure },
    };
}

const SensitiveExitCode = union(enum) {
    code: u8,
    failure: RemoteFailure,
};

fn sensitiveExitCode(command: *const SensitiveRemoteCommand, phase: CommandPhase) SensitiveExitCode {
    if (command.* == .completed and command.completed.term == .exited)
        return .{ .code = command.completed.term.exited };
    return .{ .failure = commandFailure(command, false, phase).? };
}

const BranchOidInspection = union(enum) {
    matches,
    context_changed,
    branch_changed,
    oid_changed,
    failed: RemoteFailure,
};

fn inspectCurrentBranchAndOid(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
    branch: []const u8,
    oid: []const u8,
) BranchOidInspection {
    const branch_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "HEAD" };
    var branch_command = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &branch_argv);
    defer branch_command.deinit();
    switch (sensitiveExitCode(&branch_command, .read_only)) {
        .failure => |failure| return switch (failure) {
            .failed => .context_changed,
            else => .{ .failed = failure },
        },
        .code => |code| if (code != 0) return .context_changed,
    }
    const expected_branch = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch}) catch
        return .{ .failed = .failed };
    defer allocator.free(expected_branch);
    const actual_branch = switch (branch_command) {
        .completed => |*result| trimLineEnd(result.stdout.bytes()),
        else => unreachable,
    };
    if (!std.mem.eql(u8, actual_branch, expected_branch)) return .branch_changed;

    const oid_argv = [_][]const u8{ "git", "rev-parse", "--verify", "HEAD" };
    var oid_command = runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &oid_argv);
    defer oid_command.deinit();
    switch (sensitiveExitCode(&oid_command, .read_only)) {
        .failure => |failure| return switch (failure) {
            .failed => .oid_changed,
            else => .{ .failed = failure },
        },
        .code => |code| if (code != 0) return .oid_changed,
    }
    const actual_oid = switch (oid_command) {
        .completed => |*result| trimLineEnd(result.stdout.bytes()),
        else => unreachable,
    };
    return if (std.mem.eql(u8, actual_oid, oid)) .matches else .oid_changed;
}

const ConfigRelation = enum {
    missing,
    expected,
    other,
    multiple,
    invalid,
};

const BooleanRelation = enum {
    missing,
    true_value,
    false_value,
    multiple,
    invalid,
};

const FinalizerReadError = error{
    VerificationFailed,
    TrackingUnknown,
};

const TrackingSnapshot = struct {
    local_remote: ConfigRelation,
    effective_remote: ConfigRelation,
    local_merge: ConfigRelation,
    effective_merge: ConfigRelation,
    local_rebase: BooleanRelation,
    effective_rebase: BooleanRelation,

    fn pairMissing(self: TrackingSnapshot) bool {
        return self.local_remote == .missing and self.effective_remote == .missing and
            self.local_merge == .missing and self.effective_merge == .missing;
    }

    fn pairExpected(self: TrackingSnapshot) bool {
        return (self.local_remote == .missing or self.local_remote == .expected) and
            self.effective_remote == .expected and
            (self.local_merge == .missing or self.local_merge == .expected) and
            self.effective_merge == .expected;
    }

    fn localAndEffectivePairExpected(self: TrackingSnapshot) bool {
        return self.local_remote == .expected and self.effective_remote == .expected and
            self.local_merge == .expected and self.effective_merge == .expected;
    }

    fn valuesAreUnambiguous(self: TrackingSnapshot) bool {
        return self.local_remote != .multiple and self.local_remote != .invalid and
            self.effective_remote != .multiple and self.effective_remote != .invalid and
            self.local_merge != .multiple and self.local_merge != .invalid and
            self.effective_merge != .multiple and self.effective_merge != .invalid and
            self.local_rebase != .multiple and self.local_rebase != .invalid and
            self.effective_rebase != .multiple and self.effective_rebase != .invalid;
    }
};

const FinalizerKeys = struct {
    expected_head: []u8,
    expected_merge: []u8,
    remote: []u8,
    merge: []u8,
    rebase: []u8,

    fn init(allocator: std.mem.Allocator, request: PushUpstreamFinalizeRequest) !FinalizerKeys {
        const expected_head = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{request.branch});
        errdefer allocator.free(expected_head);
        const expected_merge = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{request.remote_branch});
        errdefer allocator.free(expected_merge);
        const remote = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{request.branch});
        errdefer allocator.free(remote);
        const merge = try std.fmt.allocPrint(allocator, "branch.{s}.merge", .{request.branch});
        errdefer allocator.free(merge);
        const rebase = try std.fmt.allocPrint(allocator, "branch.{s}.rebase", .{request.branch});
        return .{
            .expected_head = expected_head,
            .expected_merge = expected_merge,
            .remote = remote,
            .merge = merge,
            .rebase = rebase,
        };
    }

    fn deinit(self: *FinalizerKeys, allocator: std.mem.Allocator) void {
        allocator.free(self.expected_head);
        allocator.free(self.expected_merge);
        allocator.free(self.remote);
        allocator.free(self.merge);
        allocator.free(self.rebase);
        self.* = undefined;
    }
};

fn runPushUpstreamFinalizer(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
) PushUpstreamFinalizeOutcome {
    var keys = FinalizerKeys.init(allocator, request) catch return .config_verification_failed;
    defer keys.deinit(allocator);

    switch (validatePushRefNames(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        request.branch,
        request.remote_branch,
    )) {
        .valid => {},
        .invalid => return .context_changed,
        .failed => |failure| return finalizerFailureBeforeWrite(failure),
    }

    if (finalizerContextOutcome(allocator, io, request, false)) |outcome| return outcome;
    const desired_rebase = readAutoSetupRebase(allocator, io, request, false) catch |err|
        return finalizerReadOutcome(err);
    var snapshot = readTrackingSnapshot(allocator, io, request, &keys, false) catch |err|
        return finalizerReadOutcome(err);
    if (!snapshot.valuesAreUnambiguous()) return .config_verification_failed;

    if (snapshot.pairExpected()) {
        if (desired_rebase and snapshot.effective_rebase != .true_value)
            return .upstream_conflict;
        return .already_configured;
    }
    if (!snapshot.pairMissing()) return .upstream_conflict;

    if (finalizerContextOutcome(allocator, io, request, false)) |outcome| return outcome;
    snapshot = readTrackingSnapshot(allocator, io, request, &keys, false) catch |err|
        return finalizerReadOutcome(err);
    if (!snapshot.valuesAreUnambiguous()) return .config_verification_failed;
    if (snapshot.pairExpected()) return .upstream_conflict;
    if (!snapshot.pairMissing()) return .upstream_conflict;

    switch (writeLocalConfig(allocator, io, request, keys.remote, request.remote)) {
        .written => {},
        .failed => return .config_write_failed,
        .unknown => return .tracking_unknown,
    }

    if (finalizerContextOutcome(allocator, io, request, true)) |outcome| return outcome;
    snapshot = readTrackingSnapshot(allocator, io, request, &keys, true) catch |err|
        return finalizerReadOutcome(err);
    if (!snapshot.valuesAreUnambiguous()) return .tracking_unknown;
    if (snapshot.local_remote != .expected or snapshot.effective_remote != .expected or
        snapshot.local_merge != .missing or snapshot.effective_merge != .missing)
        return .upstream_conflict;

    switch (writeLocalConfig(allocator, io, request, keys.merge, keys.expected_merge)) {
        .written => {},
        .failed => return .config_write_failed,
        .unknown => return .tracking_unknown,
    }

    if (finalizerContextOutcome(allocator, io, request, true)) |outcome| return outcome;
    snapshot = readTrackingSnapshot(allocator, io, request, &keys, true) catch |err|
        return finalizerReadOutcome(err);
    if (!snapshot.valuesAreUnambiguous() or !snapshot.localAndEffectivePairExpected())
        return .upstream_conflict;

    if (desired_rebase and snapshot.effective_rebase != .true_value) {
        if (snapshot.effective_rebase != .missing and snapshot.effective_rebase != .false_value)
            return .upstream_conflict;
        switch (writeLocalConfig(allocator, io, request, keys.rebase, "true")) {
            .written => {},
            .failed => return .config_write_failed,
            .unknown => return .tracking_unknown,
        }
    }

    if (finalizerContextOutcome(allocator, io, request, true)) |outcome| return outcome;
    snapshot = readTrackingSnapshot(allocator, io, request, &keys, true) catch |err|
        return finalizerReadOutcome(err);
    if (!snapshot.valuesAreUnambiguous() or !snapshot.localAndEffectivePairExpected())
        return .config_verification_failed;
    if (desired_rebase and
        (snapshot.local_rebase != .true_value or snapshot.effective_rebase != .true_value))
        return .config_verification_failed;
    return .configured;
}

fn finalizerFailureBeforeWrite(failure: RemoteFailure) PushUpstreamFinalizeOutcome {
    return switch (failure) {
        .canceled, .timed_out, .outcome_unknown, .canceled_outcome_unknown, .timed_out_outcome_unknown => .tracking_unknown,
        else => .config_verification_failed,
    };
}

fn finalizerReadOutcome(err: FinalizerReadError) PushUpstreamFinalizeOutcome {
    return switch (err) {
        error.VerificationFailed => .config_verification_failed,
        error.TrackingUnknown => .tracking_unknown,
    };
}

fn finalizerContextOutcome(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
    mutation_started: bool,
) ?PushUpstreamFinalizeOutcome {
    return switch (inspectCurrentBranchAndOid(
        allocator,
        io,
        request.root.dir(),
        &request.environment.map,
        request.control,
        request.branch,
        request.oid,
    )) {
        .matches => null,
        .context_changed => .context_changed,
        .branch_changed => .branch_changed,
        .oid_changed => .oid_changed,
        .failed => |failure| if (mutation_started)
            .tracking_unknown
        else
            finalizerFailureBeforeWrite(failure),
    };
}

fn readAutoSetupRebase(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
    mutation_started: bool,
) FinalizerReadError!bool {
    const argv = [_][]const u8{ "git", "config", "--null", "--get-all", "branch.autoSetupRebase" };
    var command = runSensitiveRemoteCommand(allocator, io, request.root.dir(), &request.environment.map, request.control, &argv);
    defer command.deinit();
    switch (sensitiveExitCode(&command, .read_only)) {
        .failure => |failure| return finalizerReadFailure(failure, mutation_started),
        .code => |code| {
            if (code == 1) return false;
            if (code != 0) return error.VerificationFailed;
        },
    }
    const bytes = switch (command) {
        .completed => |*result| result.stdout.bytes(),
        else => unreachable,
    };
    const value = singleNulValue(bytes) orelse return error.VerificationFailed;
    if (std.ascii.eqlIgnoreCase(value, "remote") or std.ascii.eqlIgnoreCase(value, "always")) return true;
    if (std.ascii.eqlIgnoreCase(value, "never") or std.ascii.eqlIgnoreCase(value, "local")) return false;
    return error.VerificationFailed;
}

fn readTrackingSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
    keys: *const FinalizerKeys,
    mutation_started: bool,
) FinalizerReadError!TrackingSnapshot {
    return .{
        .local_remote = try readConfigRelation(allocator, io, request, true, keys.remote, request.remote, mutation_started),
        .effective_remote = try readConfigRelation(allocator, io, request, false, keys.remote, request.remote, mutation_started),
        .local_merge = try readConfigRelation(allocator, io, request, true, keys.merge, keys.expected_merge, mutation_started),
        .effective_merge = try readConfigRelation(allocator, io, request, false, keys.merge, keys.expected_merge, mutation_started),
        .local_rebase = try readBooleanRelation(allocator, io, request, true, keys.rebase, mutation_started),
        .effective_rebase = try readBooleanRelation(allocator, io, request, false, keys.rebase, mutation_started),
    };
}

fn readConfigRelation(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
    local: bool,
    key: []const u8,
    expected: []const u8,
    mutation_started: bool,
) FinalizerReadError!ConfigRelation {
    const local_argv = [_][]const u8{ "git", "config", "--local", "--null", "--get-all", key };
    const effective_argv = [_][]const u8{ "git", "config", "--null", "--get-all", key };
    const argv: []const []const u8 = if (local) &local_argv else &effective_argv;
    var command = runSensitiveRemoteCommand(allocator, io, request.root.dir(), &request.environment.map, request.control, argv);
    defer command.deinit();
    switch (sensitiveExitCode(&command, .read_only)) {
        .failure => |failure| return finalizerReadFailure(failure, mutation_started),
        .code => |code| {
            if (code == 1) return .missing;
            if (code != 0) return error.VerificationFailed;
        },
    }
    const bytes = switch (command) {
        .completed => |*result| result.stdout.bytes(),
        else => unreachable,
    };
    return configRelationFromBytes(bytes, expected);
}

fn readBooleanRelation(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
    local: bool,
    key: []const u8,
    mutation_started: bool,
) FinalizerReadError!BooleanRelation {
    const local_argv = [_][]const u8{ "git", "config", "--local", "--bool", "--null", "--get-all", key };
    const effective_argv = [_][]const u8{ "git", "config", "--bool", "--null", "--get-all", key };
    const argv: []const []const u8 = if (local) &local_argv else &effective_argv;
    var command = runSensitiveRemoteCommand(allocator, io, request.root.dir(), &request.environment.map, request.control, argv);
    defer command.deinit();
    switch (sensitiveExitCode(&command, .read_only)) {
        .failure => |failure| return finalizerReadFailure(failure, mutation_started),
        .code => |code| {
            if (code == 1) return .missing;
            if (code != 0) return error.VerificationFailed;
        },
    }
    const bytes = switch (command) {
        .completed => |*result| result.stdout.bytes(),
        else => unreachable,
    };
    const value = singleNulValue(bytes) orelse return if (countNulValues(bytes) > 1) .multiple else .invalid;
    if (std.ascii.eqlIgnoreCase(value, "true")) return .true_value;
    if (std.ascii.eqlIgnoreCase(value, "false")) return .false_value;
    return .invalid;
}

fn finalizerReadFailure(failure: RemoteFailure, mutation_started: bool) FinalizerReadError {
    if (mutation_started or failure == .canceled or failure == .timed_out or
        failure == .outcome_unknown or failure == .canceled_outcome_unknown or failure == .timed_out_outcome_unknown)
        return error.TrackingUnknown;
    return error.VerificationFailed;
}

fn configRelationFromBytes(bytes: []const u8, expected: []const u8) ConfigRelation {
    const value = singleNulValue(bytes) orelse return if (countNulValues(bytes) > 1) .multiple else .invalid;
    return if (std.mem.eql(u8, value, expected)) .expected else .other;
}

fn singleNulValue(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return null;
    if (std.mem.indexOfScalar(u8, bytes[0 .. bytes.len - 1], 0) != null) return null;
    return bytes[0 .. bytes.len - 1];
}

fn countNulValues(bytes: []const u8) usize {
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return 0;
    return std.mem.count(u8, bytes, &.{0});
}

const ConfigWriteResult = enum { written, failed, unknown };

fn writeLocalConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: PushUpstreamFinalizeRequest,
    key: []const u8,
    value: []const u8,
) ConfigWriteResult {
    const argv = [_][]const u8{ "git", "config", "--local", "--replace-all", key, value };
    var command = runSensitiveRemoteCommand(allocator, io, request.root.dir(), &request.environment.map, request.control, &argv);
    defer command.deinit();
    return switch (sensitiveExitCode(&command, .may_update)) {
        .code => |code| if (code == 0) .written else .failed,
        .failure => |failure| switch (failure) {
            .outcome_unknown, .canceled_outcome_unknown, .timed_out_outcome_unknown => .unknown,
            else => .failed,
        },
    };
}

fn runSecureGitPush(
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: RemoteOperationRequest,
    request: PushRequest,
    warnings: RemoteWarningSet,
) RemoteOperationResult {
    switch (secureRemoteBranchSnapshotMatches(allocator, io, operation, request.branch, request.oid, .read_only)) {
        .matches => {},
        .mismatch => return remoteFailureResult(.failed, warnings),
        .failed => |failure| return remoteFailureResult(failure, warnings),
    }

    const refspec = std.fmt.allocPrint(allocator, "{s}:refs/heads/{s}", .{ request.oid, request.remote_branch }) catch
        return remoteFailureResult(.failed, warnings);
    defer allocator.free(refspec);
    const argv = [_][]const u8{
        "git",   "-c",                           "credential.interactive=false", "-c",                     "credential.trace=false", "-c", "credential.traceSecrets=false",
        "-c",    "credential.traceMsAuth=false", "-c",                           "credential.debug=false", "push",                   "--", request.remote,
        refspec,
    };
    var command = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &argv);
    defer command.deinit();
    if (commandFailure(&command, true, .may_update)) |failure| return remoteFailureResult(failure, warnings);
    if (request.mode == .set_upstream) {
        var environment = buildRemoteEnvironment(allocator, &operation.environment.map, .local_finalizer) catch
            return remoteSuccessResult(.push_tracking_incomplete, warnings);
        defer environment.deinit();
        switch (runPushUpstreamFinalizer(allocator, io, .{
            .root = operation.root,
            .environment = &environment,
            .control = operation.control,
            .branch = request.branch,
            .remote = request.remote,
            .remote_branch = request.remote_branch,
            .oid = request.oid,
        })) {
            .configured, .already_configured => {},
            else => return remoteSuccessResult(.push_tracking_incomplete, warnings),
        }
    }
    return remoteSuccessResult(.completed, warnings);
}

fn runSecureGitFetch(
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: RemoteOperationRequest,
    request: FetchRequest,
    warnings: RemoteWarningSet,
) RemoteOperationResult {
    const argv = [_][]const u8{
        "git", "-c",                           "credential.interactive=false", "-c",                     "credential.trace=false", "-c", "credential.traceSecrets=false",
        "-c",  "credential.traceMsAuth=false", "-c",                           "credential.debug=false", "fetch",                  "--", request.remote,
    };
    var command = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &argv);
    defer command.deinit();
    if (commandFailure(&command, true, .may_update)) |failure| return remoteFailureResult(failure, warnings);
    return remoteSuccessResult(.completed, warnings);
}

fn runSecureGitPull(
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: RemoteOperationRequest,
    request: PullRequest,
    warnings: RemoteWarningSet,
) RemoteOperationResult {
    switch (securePullPreconditionsMatch(allocator, io, operation, request, .read_only)) {
        .matches => {},
        .mismatch => return remoteFailureResult(.failed, warnings),
        .failed => |failure| return remoteFailureResult(failure, warnings),
    }

    const fetch_argv = [_][]const u8{
        "git", "-c",                           "credential.interactive=false", "-c",                     "credential.trace=false", "-c", "credential.traceSecrets=false",
        "-c",  "credential.traceMsAuth=false", "-c",                           "credential.debug=false", "fetch",                  "--", request.remote,
    };
    var fetch = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &fetch_argv);
    defer fetch.deinit();
    if (commandFailure(&fetch, true, .may_update)) |failure| return remoteFailureResult(failure, warnings);

    switch (securePullPreconditionsMatch(allocator, io, operation, request, .after_update)) {
        .matches => {},
        .mismatch => return remoteFailureResult(.failed, warnings),
        .failed => |failure| return remoteFailureResult(failure, warnings),
    }

    const spec = std.fmt.allocPrint(allocator, "HEAD...{s}", .{request.upstream_ref}) catch
        return remoteFailureResult(.failed, warnings);
    defer allocator.free(spec);
    const ahead_behind_argv = [_][]const u8{ "git", "rev-list", "--left-right", "--count", spec };
    var ahead_behind_command = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &ahead_behind_argv);
    defer ahead_behind_command.deinit();
    if (commandFailure(&ahead_behind_command, false, .after_update)) |failure| return remoteFailureResult(failure, warnings);
    const ahead_behind_bytes = switch (ahead_behind_command) {
        .completed => |*result| result.stdout.bytes(),
        else => unreachable,
    };
    const ahead_behind = parseRevListAheadBehind(ahead_behind_bytes) catch
        return remoteFailureResult(.failed, warnings);
    if (ahead_behind.ahead == 0 and ahead_behind.behind == 0)
        return remoteSuccessResult(.already_up_to_date, warnings);
    if (ahead_behind.ahead != 0) return remoteFailureResult(.failed, warnings);

    const merge_argv = [_][]const u8{ "git", "merge", "--ff-only", request.upstream_ref };
    var merge = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &merge_argv);
    defer merge.deinit();
    if (commandFailure(&merge, false, .after_update)) |failure| return remoteFailureResult(failure, warnings);
    return remoteSuccessResult(.completed, warnings);
}

fn securePullPreconditionsMatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: RemoteOperationRequest,
    request: PullRequest,
    phase: CommandPhase,
) RemoteCheck {
    switch (secureRemoteBranchSnapshotMatches(allocator, io, operation, request.branch, request.oid, phase)) {
        .matches => {},
        .mismatch => return .mismatch,
        .failed => |failure| return .{ .failed = failure },
    }

    const local_ref = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{request.branch}) catch return .{ .failed = .failed };
    defer allocator.free(local_ref);
    const upstream_argv = [_][]const u8{ "git", "for-each-ref", git_branch_status.upstream_format, "--", local_ref };
    var upstream = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &upstream_argv);
    defer upstream.deinit();
    if (commandFailure(&upstream, false, phase)) |failure| return .{ .failed = failure };
    const actual = switch (upstream) {
        .completed => |*result| (git_branch_status.parseUpstreamRecord(result.stdout.bytes(), local_ref) catch return .{ .failed = .failed }) orelse return .mismatch,
        else => unreachable,
    };
    if (!std.mem.eql(u8, actual.remote, request.remote) or
        !std.mem.eql(u8, actual.remote_branch, request.remote_branch) or
        !std.mem.eql(u8, actual.full_ref, request.upstream_ref)) return .mismatch;

    const status_argv = [_][]const u8{ "git", "status", "--porcelain=v1", "-z", "-uall" };
    var status = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &status_argv);
    defer status.deinit();
    if (commandFailure(&status, false, phase)) |failure| return .{ .failed = failure };
    return switch (status) {
        .completed => |*result| if (result.stdout.bytes().len == 0) .matches else .mismatch,
        else => unreachable,
    };
}

fn secureRemoteBranchSnapshotMatches(
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: RemoteOperationRequest,
    branch: []const u8,
    oid: []const u8,
    phase: CommandPhase,
) RemoteCheck {
    const branch_argv = [_][]const u8{ "git", "symbolic-ref", "--quiet", "HEAD" };
    var branch_command = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &branch_argv);
    defer branch_command.deinit();
    if (commandFailure(&branch_command, false, phase)) |failure| return .{ .failed = failure };
    const actual_branch = switch (branch_command) {
        .completed => |*result| git_ref.localBranchName(trimLineEnd(result.stdout.bytes())) orelse return .mismatch,
        else => unreachable,
    };
    if (!std.mem.eql(u8, actual_branch, branch)) return .mismatch;

    const oid_argv = [_][]const u8{ "git", "rev-parse", "--verify", "HEAD" };
    var oid_command = runSensitiveRemoteCommand(allocator, io, operation.root.dir(), &operation.environment.map, operation.control, &oid_argv);
    defer oid_command.deinit();
    if (commandFailure(&oid_command, false, phase)) |failure| return .{ .failed = failure };
    const actual_oid = switch (oid_command) {
        .completed => |*result| trimLineEnd(result.stdout.bytes()),
        else => unreachable,
    };
    return if (std.mem.eql(u8, actual_oid, oid)) .matches else .mismatch;
}

/// Build a remote-child environment from the reviewed non-secret allowlist.
///
/// This is intentionally not an ambient clone. The returned map owns every
/// key/value and can be released immediately after a synchronous child call or
/// after Chasen has deep-copied a foreground request.
pub fn buildRemoteEnvironment(
    allocator: std.mem.Allocator,
    parent: ?*const std.process.Environ.Map,
    mode: RemoteEnvironmentMode,
) std.mem.Allocator.Error!OwnedRemoteEnvironment {
    var owned: OwnedRemoteEnvironment = .{
        .map = std.process.Environ.Map.init(allocator),
    };
    errdefer owned.deinit();

    if (parent) |source| {
        const local_exact = [_][]const u8{
            "PATH",
            "HOME",
            "LANG",
            "LANGUAGE",
            "TZ",
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "XDG_CACHE_HOME",
            "XDG_RUNTIME_DIR",
        };
        for (local_exact) |key| try copyRemoteEnvironmentKey(&owned.map, source, key);
        for (source.keys(), source.values()) |key, value|
            if (isLocaleEnvironmentKey(key)) try owned.map.put(key, value);

        const remote_exact = [_][]const u8{
            "USER",
            "LOGNAME",
            "SHELL",
            "TMPDIR",
            "SSH_AUTH_SOCK",
            "SSH_AGENT_PID",
            "GNUPGHOME",
            "DBUS_SESSION_BUS_ADDRESS",
            "SSL_CERT_FILE",
            "SSL_CERT_DIR",
            "GCM_CREDENTIAL_STORE",
            "GCM_CREDENTIAL_CACHE_OPTIONS",
            "GCM_PLAINTEXT_STORE_PATH",
            "GCM_DPAPI_STORE_PATH",
            "GCM_GPG_PATH",
            "GCM_PROVIDER",
            "GCM_AUTODETECT_TIMEOUT",
            "GCM_MSAUTH_FLOW",
        };
        if (mode != .local_finalizer) {
            for (remote_exact) |key| try copyRemoteEnvironmentKey(&owned.map, source, key);

            const proxy_keys = [_][]const u8{
                "HTTP_PROXY",
                "HTTPS_PROXY",
                "ALL_PROXY",
                "NO_PROXY",
                "http_proxy",
                "https_proxy",
                "all_proxy",
                "no_proxy",
            };
            for (proxy_keys) |key| {
                const value = source.get(key) orelse continue;
                if (proxyContainsUserInfo(value)) {
                    owned.warnings.proxy_credentials_omitted = true;
                } else {
                    try owned.map.put(key, value);
                }
            }
        }
        if (mode == .foreground) {
            const foreground_exact = [_][]const u8{
                "XDG_CURRENT_DESKTOP",
                "XDG_SESSION_TYPE",
                "DISPLAY",
                "WAYLAND_DISPLAY",
                "BROWSER",
                "TERM",
                "COLORTERM",
                "SSH_TTY",
                "GPG_TTY",
                "GCM_GUI_PROMPT",
            };
            for (foreground_exact) |key| try copyRemoteEnvironmentKey(&owned.map, source, key);
        }
    }

    switch (mode) {
        .background, .inspection => {
            try owned.map.put("GIT_TERMINAL_PROMPT", "0");
            try owned.map.put("GCM_INTERACTIVE", "0");
            try owned.map.put("GCM_GUI_PROMPT", "0");
            try owned.map.put("GIT_SSH_COMMAND", "ssh -o BatchMode=yes");
        },
        .foreground => try owned.map.put("GCM_INTERACTIVE", "1"),
        .local_finalizer => {
            try owned.map.put("GIT_TERMINAL_PROMPT", "0");
            try owned.map.put("GCM_INTERACTIVE", "0");
            try owned.map.put("GCM_GUI_PROMPT", "0");
        },
    }
    return owned;
}

/// Own the fixed argv/refspec and reviewed foreground environment for one
/// already-inspected push. This function prepares data only; App code retains
/// repository authority and owns Chasen effect admission and lifecycle.
pub fn prepareForegroundPush(
    allocator: std.mem.Allocator,
    parent: ?*const std.process.Environ.Map,
    push: PushRequest,
    inspection_warnings: RemoteWarningSet,
) std.mem.Allocator.Error!PreparedForegroundPush {
    const remote = try allocator.dupe(u8, push.remote);
    errdefer allocator.free(remote);

    const refspec = try std.fmt.allocPrint(
        allocator,
        "{s}:refs/heads/{s}",
        .{ push.oid, push.remote_branch },
    );
    errdefer allocator.free(refspec);

    var environment = try buildRemoteEnvironment(allocator, parent, .foreground);
    errdefer environment.deinit();
    environment.warnings.merge(inspection_warnings);

    return .{
        .argv = .{
            "git",
            "-c",
            "credential.trace=false",
            "-c",
            "credential.traceSecrets=false",
            "-c",
            "credential.traceMsAuth=false",
            "-c",
            "credential.debug=false",
            "push",
            "--",
            remote,
            refspec,
        },
        .remote = remote,
        .refspec = refspec,
        .environment = environment,
    };
}

fn copyRemoteEnvironmentKey(
    destination: *std.process.Environ.Map,
    source: *const std.process.Environ.Map,
    key: []const u8,
) std.mem.Allocator.Error!void {
    if (source.get(key)) |value| try destination.put(key, value);
}

fn isLocaleEnvironmentKey(key: []const u8) bool {
    return switch (builtin.os.tag) {
        .windows => std.ascii.startsWithIgnoreCase(key, "LC_"),
        else => std.mem.startsWith(u8, key, "LC_"),
    };
}

fn proxyContainsUserInfo(value: []const u8) bool {
    if (std.Uri.parse(value)) |uri| {
        if (uri.user != null or uri.password != null) return true;
        if (uri.host != null) return false;
    } else |_| {}

    var authority = value;
    if (std.mem.indexOf(u8, authority, "://")) |scheme_end| authority = authority[scheme_end + 3 ..];
    const authority_end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
    return std.mem.indexOfScalar(u8, authority[0..authority_end], '@') != null;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn writeExecutableRemoteTestScript(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    contents: []const u8,
) !void {
    try dir.writeFile(io, .{
        .sub_path = sub_path,
        .data = contents,
        .flags = .{ .permissions = .executable_file },
    });
}

fn runBackgroundCredentialFill(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    control: process_runner.ProcessControl,
) SensitiveRemoteCommand {
    const argv = [_][]const u8{
        "sh",
        "-c",
        "printf 'protocol=https\\nhost=example.invalid\\n\\n' | git -c credential.interactive=false credential fill",
    };
    return runSensitiveRemoteCommand(allocator, io, cwd, environment, control, &argv);
}

fn configureRemoteTestHelper(
    allocator: std.mem.Allocator,
    io: std.Io,
    work: std.Io.Dir,
    helper_path: []const u8,
) !void {
    const helper = try std.fmt.allocPrint(allocator, "!{s}", .{helper_path});
    defer allocator.free(helper);
    try runTestGit(io, &.{ "git", "config", "--local", "--replace-all", "credential.helper", "" }, work);
    try runTestGit(io, &.{ "git", "config", "--local", "--add", "credential.helper", helper }, work);
}

test "foreground and background remote operation environment own the exact allowlist" {
    const allocator = std.testing.allocator;
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();

    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", "/home/test");
    try parent.put("LC_TIME", "C");
    try parent.put("XDG_RUNTIME_DIR", "/run/user/test");
    try parent.put("SSH_AUTH_SOCK", "/run/agent.sock");
    try parent.put("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/dbus");
    try parent.put("SSL_CERT_FILE", "/etc/certs.pem");
    try parent.put("TERM", "xterm-256color");
    try parent.put("DISPLAY", ":0");
    try parent.put("GCM_GUI_PROMPT", "true");
    try parent.put("GCM_CREDENTIAL_STORE", "secretservice");

    try parent.put("XDG_STATE_HOME", "/forbidden/state");
    try parent.put("GIT_DIR", "/forbidden/repo");
    try parent.put("GIT_WORK_TREE", "/forbidden/worktree");
    try parent.put("GIT_CONFIG_COUNT", "1");
    try parent.put("GIT_CONFIG_KEY_0", "http.extraHeader");
    try parent.put("GIT_CONFIG_VALUE_0", "Authorization: CONFIG-SECRET-CANARY");
    try parent.put("GCM_TRACE", "1");
    try parent.put("GCM_DEBUG", "1");
    try parent.put("GCM_AZREPOS_SP_SECRET", "GCM-SECRET-CANARY");
    try parent.put("GITHUB_TOKEN", "PROVIDER-SECRET-CANARY");
    try parent.put("GCM_INTERACTIVE", "0");

    var background = try buildRemoteEnvironment(allocator, &parent, .background);
    defer background.deinit();
    try std.testing.expectEqualStrings("/home/test", background.map.get("HOME").?);
    try std.testing.expectEqualStrings("C", background.map.get("LC_TIME").?);
    try std.testing.expectEqualStrings("/run/agent.sock", background.map.get("SSH_AUTH_SOCK").?);
    try std.testing.expectEqualStrings("unix:path=/run/dbus", background.map.get("DBUS_SESSION_BUS_ADDRESS").?);
    try std.testing.expectEqualStrings("/etc/certs.pem", background.map.get("SSL_CERT_FILE").?);
    try std.testing.expectEqualStrings("secretservice", background.map.get("GCM_CREDENTIAL_STORE").?);
    try std.testing.expect(background.map.get("TERM") == null);
    try std.testing.expect(background.map.get("DISPLAY") == null);
    try std.testing.expectEqualStrings("0", background.map.get("GCM_GUI_PROMPT").?);
    try std.testing.expectEqualStrings("0", background.map.get("GCM_INTERACTIVE").?);
    try std.testing.expectEqualStrings("0", background.map.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("ssh -o BatchMode=yes", background.map.get("GIT_SSH_COMMAND").?);

    var foreground = try buildRemoteEnvironment(allocator, &parent, .foreground);
    defer foreground.deinit();
    try std.testing.expectEqualStrings("xterm-256color", foreground.map.get("TERM").?);
    try std.testing.expectEqualStrings(":0", foreground.map.get("DISPLAY").?);
    try std.testing.expectEqualStrings("true", foreground.map.get("GCM_GUI_PROMPT").?);
    try std.testing.expectEqualStrings("1", foreground.map.get("GCM_INTERACTIVE").?);

    var local_finalizer = try buildRemoteEnvironment(allocator, &parent, .local_finalizer);
    defer local_finalizer.deinit();
    try std.testing.expectEqualStrings("/usr/bin:/bin", local_finalizer.map.get("PATH").?);
    try std.testing.expectEqualStrings("/home/test", local_finalizer.map.get("HOME").?);
    try std.testing.expectEqualStrings("C", local_finalizer.map.get("LC_TIME").?);
    try std.testing.expectEqualStrings("/run/user/test", local_finalizer.map.get("XDG_RUNTIME_DIR").?);
    try std.testing.expectEqualStrings("0", local_finalizer.map.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("0", local_finalizer.map.get("GCM_INTERACTIVE").?);
    try std.testing.expectEqualStrings("0", local_finalizer.map.get("GCM_GUI_PROMPT").?);
    const local_forbidden = [_][]const u8{
        "SSH_AUTH_SOCK",
        "SSH_AGENT_PID",
        "DBUS_SESSION_BUS_ADDRESS",
        "SSL_CERT_FILE",
        "GCM_CREDENTIAL_STORE",
        "GCM_PROVIDER",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "TERM",
        "DISPLAY",
        "GIT_DIR",
        "GIT_CONFIG_COUNT",
    };
    for (local_forbidden) |key| try std.testing.expect(local_finalizer.map.get(key) == null);

    const forbidden = [_][]const u8{
        "XDG_STATE_HOME",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_KEY_0",
        "GIT_CONFIG_VALUE_0",
        "GCM_TRACE",
        "GCM_DEBUG",
        "GCM_AZREPOS_SP_SECRET",
        "GITHUB_TOKEN",
    };
    for (forbidden) |key| {
        try std.testing.expect(background.map.get(key) == null);
        try std.testing.expect(foreground.map.get(key) == null);
    }

    try parent.put("HOME", "/changed");
    try std.testing.expectEqualStrings("/home/test", foreground.map.get("HOME").?);
}

test "remote authentication blocks GUI interaction and bounds a noncooperating credential helper" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);

    try writeExecutableRemoteTestScript(io, tmp.dir, "cooperating-helper", "#!/bin/sh\n" ++
        ": > \"$HOME/helper-invoked\"\n" ++
        "if [ -n \"${DISPLAY:-}${WAYLAND_DISPLAY:-}${BROWSER:-}${COLORTERM:-}${SSH_TTY:-}${GPG_TTY:-}\" ]; then\n" ++
        "  : > \"$HOME/gui-attempted\"\n" ++
        "fi\n" ++
        "if [ \"${GIT_TERMINAL_PROMPT:-}\" != 0 ] || [ \"${GCM_INTERACTIVE:-}\" != 0 ] || [ \"${GCM_GUI_PROMPT:-}\" != 0 ]; then\n" ++
        "  : > \"$HOME/interaction-enabled\"\n" ++
        "fi\n" ++
        "exit 1\n");
    const helper_path = try tmp.dir.realPathFileAlloc(io, "cooperating-helper", allocator);
    defer allocator.free(helper_path);
    try configureRemoteTestHelper(allocator, io, work, helper_path);

    const home_root = try tmp.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(home_root);
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", home_root);
    try parent.put("DISPLAY", ":99");
    try parent.put("WAYLAND_DISPLAY", "wayland-canary");
    try parent.put("BROWSER", "browser-canary");
    try parent.put("TERM", "xterm-canary");
    try parent.put("COLORTERM", "truecolor-canary");
    try parent.put("SSH_TTY", "/dev/pts/canary");
    try parent.put("GPG_TTY", "/dev/pts/gpg-canary");
    var environment = try buildRemoteEnvironment(allocator, &parent, .background);
    defer environment.deinit();

    var denied = runBackgroundCredentialFill(allocator, io, work, &environment.map, .{});
    defer denied.deinit();
    try std.testing.expectEqual(RemoteFailure.failed, commandFailure(&denied, true, .read_only).?);
    try tmp.dir.access(io, "home/helper-invoked", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/gui-attempted", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/interaction-enabled", .{}));

    try writeExecutableRemoteTestScript(io, tmp.dir, "hanging-helper", "#!/bin/sh\n" ++
        ": > \"$HOME/hanging-helper-invoked\"\n" ++
        "trap '' TERM\n" ++
        "while :; do sleep 1; done\n");
    const hanging_path = try tmp.dir.realPathFileAlloc(io, "hanging-helper", allocator);
    defer allocator.free(hanging_path);
    try configureRemoteTestHelper(allocator, io, work, hanging_path);
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(250),
        .clock = .awake,
    });
    var timed_out = runBackgroundCredentialFill(allocator, io, work, &environment.map, .{ .deadline = deadline });
    defer timed_out.deinit();
    try std.testing.expect(timed_out == .timed_out);
    try tmp.dir.access(io, "home/hanging-helper-invoked", .{});
}

test "remote authentication uses a DBus cached libsecret-equivalent helper without GUI discovery" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);

    try writeExecutableRemoteTestScript(io, tmp.dir, "libsecret-fixture", "#!/bin/sh\n" ++
        "if [ -n \"${DISPLAY:-}${WAYLAND_DISPLAY:-}${BROWSER:-}${GPG_TTY:-}\" ]; then\n" ++
        "  : > \"$HOME/libsecret-gui-attempted\"\n" ++
        "  exit 1\n" ++
        "fi\n" ++
        "[ \"${DBUS_SESSION_BUS_ADDRESS:-}\" = \"unix:path=$HOME/session-bus\" ] || exit 1\n" ++
        "printf 'username=dbus-user\\npassword=DBUS-CACHED-CREDENTIAL-CANARY\\n'\n");
    const helper_path = try tmp.dir.realPathFileAlloc(io, "libsecret-fixture", allocator);
    defer allocator.free(helper_path);
    try configureRemoteTestHelper(allocator, io, work, helper_path);

    const home_root = try tmp.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(home_root);
    const dbus_address = try std.fmt.allocPrint(allocator, "unix:path={s}/session-bus", .{home_root});
    defer allocator.free(dbus_address);
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", home_root);
    try parent.put("DBUS_SESSION_BUS_ADDRESS", dbus_address);
    try parent.put("DISPLAY", ":99");
    try parent.put("BROWSER", "browser-canary");
    try parent.put("TERM", "terminal-canary");
    var environment = try buildRemoteEnvironment(allocator, &parent, .background);
    defer environment.deinit();

    try std.testing.expectEqualStrings(dbus_address, environment.map.get("DBUS_SESSION_BUS_ADDRESS").?);
    var command = runBackgroundCredentialFill(allocator, io, work, &environment.map, .{});
    defer command.deinit();
    try std.testing.expect(commandFailure(&command, true, .read_only) == null);
    const output = switch (command) {
        .completed => |*result| result.stdout.bytes(),
        else => return error.ExpectedDbusCredential,
    };
    try std.testing.expect(std.mem.indexOf(u8, output, "username=dbus-user") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "password=DBUS-CACHED-CREDENTIAL-CANARY") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/libsecret-gui-attempted", .{}));
}

test "credential helper requiring an omitted key returns only a fixed sensitive diagnostic" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);

    try writeExecutableRemoteTestScript(io, tmp.dir, "custom-key-helper", "#!/bin/sh\n" ++
        "if [ -n \"${CUSTOM_HELPER_TOKEN:-}\" ]; then\n" ++
        "  printf 'username=ambient-user\\npassword=%s\\n' \"$CUSTOM_HELPER_TOKEN\"\n" ++
        "  exit 0\n" ++
        "fi\n" ++
        "printf '%s\\n' 'Authorization: Bearer OMITTED-AUTH-CANARY' 'password=OMITTED-PASSWORD-CANARY' 'OMITTED-ARBITRARY-CANARY' >&2\n" ++
        "exit 1\n");
    const helper_path = try tmp.dir.realPathFileAlloc(io, "custom-key-helper", allocator);
    defer allocator.free(helper_path);
    try configureRemoteTestHelper(allocator, io, work, helper_path);

    const home_root = try tmp.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(home_root);
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", home_root);
    try parent.put("CUSTOM_HELPER_TOKEN", "AMBIENT-CREDENTIAL-CANARY");
    var environment = try buildRemoteEnvironment(allocator, &parent, .background);
    defer environment.deinit();
    try std.testing.expect(environment.map.get("CUSTOM_HELPER_TOKEN") == null);

    var command = runBackgroundCredentialFill(allocator, io, work, &environment.map, .{});
    defer command.deinit();
    const failure = commandFailure(&command, true, .read_only) orelse return error.ExpectedCredentialFailure;
    try std.testing.expectEqual(RemoteFailure.failed, failure);
    const raw = switch (command) {
        .completed => |*result| result.stderr.bytes(),
        else => return error.ExpectedSensitiveDiagnostic,
    };
    try std.testing.expect(std.mem.indexOf(u8, raw, "OMITTED-AUTH-CANARY") != null);
    const safe_result = remoteFailureResult(failure, environment.warnings);
    const formatted = try std.fmt.allocPrint(allocator, "{any}", .{safe_result});
    defer allocator.free(formatted);
    const canaries = [_][]const u8{
        "AMBIENT-CREDENTIAL-CANARY",
        "OMITTED-AUTH-CANARY",
        "OMITTED-PASSWORD-CANARY",
        "OMITTED-ARBITRARY-CANARY",
    };
    for (canaries) |canary| try std.testing.expect(std.mem.indexOf(u8, formatted, canary) == null);
}

test "remote URL audit rejects every fetch URL pushurl and effective push URL before network" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "bin", .default_dir);
    try tmp.dir.createDir(io, "home", .default_dir);
    try writeExecutableRemoteTestScript(io, tmp.dir, "bin/git-remote-networkmarker", "#!/bin/sh\n" ++
        ": > \"$HOME/network-started\"\n" ++
        "exit 1\n");
    const bin_root = try tmp.dir.realPathFileAlloc(io, "bin", allocator);
    defer allocator.free(bin_root);
    const home_root = try tmp.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(home_root);
    const path = try std.fmt.allocPrint(allocator, "{s}:/usr/bin:/bin", .{bin_root});
    defer allocator.free(path);
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", path);
    try parent.put("HOME", home_root);
    var environment = try buildRemoteEnvironment(allocator, &parent, .background);
    defer environment.deinit();

    try tmp.dir.createDir(io, "fetch-work", .default_dir);
    var fetch_work = try tmp.dir.openDir(io, "fetch-work", .{});
    defer fetch_work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, fetch_work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "networkmarker::first-fetch-url" }, fetch_work);
    try runTestGit(io, &.{ "git", "config", "--local", "--add", "remote.origin.url", "https://alice:FETCH-URL-CANARY@127.0.0.1:1/repo.git" }, fetch_work);
    const fetch_root_path = try tmp.dir.realPathFileAlloc(io, "fetch-work", allocator);
    defer allocator.free(fetch_root_path);
    var fetch_root = try root_capability.RootCapability.openCanonical(fetch_root_path);
    defer fetch_root.deinit();
    const fetch_result = runOperation(allocator, io, .{
        .root = &fetch_root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .fetch = .{ .remote = "origin" } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .failed = .http_userinfo_rejected }, fetch_result.outcome);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/network-started", .{}));

    try tmp.dir.createDir(io, "pushurl-work", .default_dir);
    var pushurl_work = try tmp.dir.openDir(io, "pushurl-work", .{});
    defer pushurl_work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, pushurl_work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "networkmarker::default-push-url" }, pushurl_work);
    try runTestGit(io, &.{ "git", "config", "--local", "--add", "remote.origin.pushurl", "networkmarker::first-pushurl" }, pushurl_work);
    try runTestGit(io, &.{ "git", "config", "--local", "--add", "remote.origin.pushurl", "https://bob:PUSHURL-CANARY@127.0.0.1:1/repo.git" }, pushurl_work);
    const pushurl_root_path = try tmp.dir.realPathFileAlloc(io, "pushurl-work", allocator);
    defer allocator.free(pushurl_root_path);
    var pushurl_root = try root_capability.RootCapability.openCanonical(pushurl_root_path);
    defer pushurl_root.deinit();
    const pushurl_result = runOperation(allocator, io, .{
        .root = &pushurl_root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .push = .{
            .mode = .upstream,
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = "deadbeef",
        } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .failed = .http_userinfo_rejected }, pushurl_result.outcome);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/network-started", .{}));

    try tmp.dir.createDir(io, "effective-push-work", .default_dir);
    var effective_work = try tmp.dir.openDir(io, "effective-push-work", .{});
    defer effective_work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, effective_work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "fixture-alias:repo" }, effective_work);
    try runTestGit(io, &.{ "git", "config", "--local", "url.https://carol:EFFECTIVE-PUSH-CANARY@127.0.0.1:1/.pushInsteadOf", "fixture-alias:" }, effective_work);
    const effective_root_path = try tmp.dir.realPathFileAlloc(io, "effective-push-work", allocator);
    defer allocator.free(effective_root_path);
    var effective_root = try root_capability.RootCapability.openCanonical(effective_root_path);
    defer effective_root.deinit();
    const effective_result = runOperation(allocator, io, .{
        .root = &effective_root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .push = .{
            .mode = .upstream,
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = "deadbeef",
        } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .failed = .http_userinfo_rejected }, effective_result.outcome);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "home/network-started", .{}));
}

test "sensitive diagnostic from a production remote helper cannot cross the typed result boundary" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "bin", .default_dir);
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    try writeExecutableRemoteTestScript(io, tmp.dir, "bin/git-remote-redactfixture", "#!/bin/sh\n" ++
        ": > \"$HOME/raw-helper-invoked\"\n" ++
        "printf '%s\\n' 'https://alice:RAW-URL-CANARY@example.invalid/repo.git' 'Authorization: Bearer RAW-AUTH-CANARY' 'password=RAW-PASSWORD-CANARY' 'RAW-ARBITRARY-CANARY' >&2\n" ++
        "exit 1\n");
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "redactfixture::opaque" }, work);

    const bin_root = try tmp.dir.realPathFileAlloc(io, "bin", allocator);
    defer allocator.free(bin_root);
    const home_root = try tmp.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(home_root);
    const path = try std.fmt.allocPrint(allocator, "{s}:/usr/bin:/bin", .{bin_root});
    defer allocator.free(path);
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", path);
    try parent.put("HOME", home_root);
    var environment = try buildRemoteEnvironment(allocator, &parent, .background);
    defer environment.deinit();
    const work_root_path = try tmp.dir.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(work_root_path);
    var root = try root_capability.RootCapability.openCanonical(work_root_path);
    defer root.deinit();

    const result = runOperation(allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .fetch = .{ .remote = "origin" } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .failed = .failed }, result.outcome);
    try tmp.dir.access(io, "home/raw-helper-invoked", .{});
    const formatted = try std.fmt.allocPrint(allocator, "{any}", .{result});
    defer allocator.free(formatted);
    const canaries = [_][]const u8{
        "RAW-URL-CANARY",
        "RAW-AUTH-CANARY",
        "RAW-PASSWORD-CANARY",
        "RAW-ARBITRARY-CANARY",
    };
    for (canaries) |canary| try std.testing.expect(std.mem.indexOf(u8, formatted, canary) == null);
}

test "remote URL audit rejects HTTP userinfo without exposing the sensitive diagnostic" {
    try std.testing.expectEqual(UrlAudit.accepted, auditLineFramedUrls(
        "https://example.invalid/owner/repo.git\nssh://git@example.invalid/repo.git\n",
    ));
    try std.testing.expectEqual(UrlAudit.userinfo, auditLineFramedUrls(
        "https://alice:REMOTE-URL-CANARY@example.invalid/owner/repo.git\n",
    ));
    try std.testing.expectEqual(UrlAudit.userinfo, auditNulFramedUrls(
        "http://alice@example.invalid/repo.git\x00",
    ));
    try std.testing.expectEqual(UrlAudit.invalid, auditLineFramedUrls(
        "https://example.invalid/repo.git\r\n",
    ));
    try std.testing.expectEqual(UrlAudit.invalid, auditNulFramedUrls(
        "https://example.invalid/repo.git",
    ));
    try std.testing.expectEqual(UrlAudit.invalid, auditLineFramedUrls(
        "https://[invalid/repo.git\n",
    ));
    try std.testing.expectEqual(UrlAudit.invalid, auditLineFramedUrls(
        "https://exam\x01ple.invalid/repo.git\n",
    ));
    try std.testing.expect(lineFramedUrlsUseHttp(
        "ssh://git@example.invalid/repo.git\nhttps://example.invalid/owner/repo.git\n",
    ));
    try std.testing.expect(!lineFramedUrlsUseHttp(
        "git@example.invalid:owner/repo.git\nssh://git@example.invalid/repo.git\n",
    ));
}

test "credential helper classification honors reset and plaintext store" {
    var warnings: RemoteWarningSet = .{};
    try std.testing.expect(classifyHelperRecords("store\x00\x00cache\x00", &warnings));
    try std.testing.expect(!warnings.git_plaintext_store);
    try std.testing.expect(!warnings.helper_policy_unknown);

    warnings = .{};
    try std.testing.expect(classifyHelperRecords("cache\x00store\x00", &warnings));
    try std.testing.expect(warnings.git_plaintext_store);

    warnings = .{};
    try std.testing.expect(classifyHelperRecords("store --file /tmp/credentials\x00", &warnings));
    try std.testing.expect(warnings.git_plaintext_store);

    warnings = .{};
    try std.testing.expect(classifyHelperRecords("!custom wrapper\x00", &warnings));
    try std.testing.expect(warnings.helper_policy_unknown);

    warnings = .{};
    try std.testing.expect(classifyHelperRecords("!custom wrapper\x00\x00cache\x00", &warnings));
    try std.testing.expect(!warnings.helper_policy_unknown);

    warnings = .{};
    try std.testing.expect(classifyHelperOrigins("file:.git/config\x00cache\x00file:/tmp/included.conf\x00store\x00", &warnings));
    try std.testing.expect(warnings.potential_plaintext_store);
    try std.testing.expect(nulSingleValueEquals("plaintext\x00", "plaintext"));

    warnings = .{};
    try std.testing.expect(classifyScopedHelperRecords(
        "credential.https://example.invalid.helper\ncache --timeout 60\x00" ++
            "credential.https://other.invalid.helper\nstore --file /tmp/credentials\x00" ++
            "credential.https://third.invalid.helper\n!custom wrapper\x00",
        &warnings,
    ));
    try std.testing.expect(warnings.potential_plaintext_store);
    try std.testing.expect(warnings.helper_policy_unknown);

    warnings = .{ .git_plaintext_store = true, .helper_policy_unknown = true };
    filterCredentialWarningsForRemote(&warnings, false);
    try std.testing.expect(warnings.git_plaintext_store);
    try std.testing.expect(!warnings.helper_policy_unknown);

    warnings = .{ .helper_policy_unknown = true };
    filterCredentialWarningsForRemote(&warnings, true);
    try std.testing.expect(warnings.helper_policy_unknown);
}

test "remote authentication failure becomes a typed sensitive diagnostic" {
    const canary = "Authorization: Basic SENSITIVE-DIAGNOSTIC-CANARY";
    try std.testing.expectEqual(
        RemoteFailure.authentication_required,
        diagnoseRemoteFailure(canary, "fatal: could not read Username: terminal prompts disabled"),
    );
    try std.testing.expectEqual(
        RemoteFailure.ssh_public_key,
        diagnoseRemoteFailure(canary, "git@example.invalid: Permission denied (publickey)."),
    );
    try std.testing.expectEqual(
        RemoteFailure.failed,
        diagnoseRemoteFailure(canary, "arbitrary remote failure"),
    );
}

test "remote failures preserve command phase and earlier updates" {
    const Case = struct {
        command: SensitiveRemoteCommand,
        phase: CommandPhase,
        expected: RemoteFailure,
    };
    const cases = [_]Case{
        .{ .command = .{ .failed = .{ .spawn = error.FileNotFound } }, .phase = .may_update, .expected = .spawn_failed },
        .{ .command = .{ .failed = .{ .spawn = error.FileNotFound } }, .phase = .after_update, .expected = .outcome_unknown },
        .{ .command = .{ .failed = .{ .capture = error.StreamTooLong } }, .phase = .read_only, .expected = .failed },
        .{ .command = .{ .failed = .{ .capture = error.StreamTooLong } }, .phase = .may_update, .expected = .outcome_unknown },
        .{ .command = .{ .failed = .{ .wait = error.InjectedWaitFailure } }, .phase = .may_update, .expected = .outcome_unknown },
        .{ .command = .{ .failed = .{ .terminate = error.PermissionDenied } }, .phase = .may_update, .expected = .outcome_unknown },
        .{ .command = .{ .canceled = .started }, .phase = .read_only, .expected = .canceled },
        .{ .command = .{ .canceled = .not_started }, .phase = .may_update, .expected = .canceled },
        .{ .command = .{ .canceled = .started }, .phase = .may_update, .expected = .canceled_outcome_unknown },
        .{ .command = .{ .timed_out = .not_started }, .phase = .may_update, .expected = .timed_out },
        .{ .command = .{ .timed_out = .started }, .phase = .may_update, .expected = .timed_out_outcome_unknown },
        .{ .command = .{ .timed_out = .not_started }, .phase = .after_update, .expected = .timed_out_outcome_unknown },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, commandFailure(&case.command, true, case.phase).?);

    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var denied = runSensitiveRemoteCommand(std.testing.allocator, std.testing.io, std.Io.Dir.cwd(), &environment, .{}, &.{ "/bin/sh", "-c", "printf 'Permission denied (publickey).' >&2; exit 1" });
    defer denied.deinit();
    try std.testing.expectEqual(RemoteFailure.ssh_public_key, commandFailure(&denied, true, .may_update).?);
}

test "remote cancel is observed before a sensitive child spawn" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var canceled_generation: std.atomic.Value(u64) = .init(9);
    const argv = [_][]const u8{ "sh", "-c", "exit 0" };
    var result = runSensitiveRemoteCommand(
        std.testing.allocator,
        std.testing.io,
        std.Io.Dir.cwd(),
        &environment,
        .{ .cancellation = .{
            .canceled_generation = &canceled_generation,
            .generation = 9,
        } },
        &argv,
    );
    defer result.deinit();
    try std.testing.expect(result == .canceled);
}

fn requestRemoteCancellation(
    io: std.Io,
    canceled_generation: *std.atomic.Value(u64),
    generation: u64,
) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(40), .awake);
    canceled_generation.store(generation, .release);
}

test "remote cancel contains a running TERM-ignoring helper process group" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("PATH", "/usr/bin:/bin");
    var canceled_generation: std.atomic.Value(u64) = .init(0);
    var cancel_future = try std.testing.io.concurrent(requestRemoteCancellation, .{
        std.testing.io,
        &canceled_generation,
        23,
    });
    defer _ = cancel_future.cancel(std.testing.io) catch {};

    const argv = [_][]const u8{
        "sh",
        "-c",
        "trap '' TERM; sh -c 'trap \"\" TERM; while :; do sleep 1; done' & while :; do sleep 1; done",
    };
    var result = runSensitiveRemoteCommand(
        std.testing.allocator,
        std.testing.io,
        std.Io.Dir.cwd(),
        &environment,
        .{ .cancellation = .{
            .canceled_generation = &canceled_generation,
            .generation = 23,
        } },
        &argv,
    );
    defer result.deinit();
    try cancel_future.await(std.testing.io);
    try std.testing.expect(result == .canceled);
}

test "remote timeout is observed before a sensitive child spawn" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const argv = [_][]const u8{ "sh", "-c", "exit 0" };
    const expired = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = .fromMilliseconds(-1),
        .clock = .awake,
    });
    var result = runSensitiveRemoteCommand(
        std.testing.allocator,
        std.testing.io,
        std.Io.Dir.cwd(),
        &environment,
        .{ .deadline = expired },
        &argv,
    );
    defer result.deinit();
    try std.testing.expect(result == .timed_out);
}

test "credential helper plaintext warning survives descriptor-bound remote authentication success" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);
    try runTestGit(io, &.{ "git", "config", "--local", "credential.helper", "store" }, work);

    const work_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(work_root);
    var root = try root_capability.RootCapability.openCanonical(work_root);
    defer root.deinit();
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .background);
    defer environment.deinit();

    const result = runOperation(std.testing.allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .fetch = .{ .remote = "origin" } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .ok = .completed }, result.outcome);
    try std.testing.expect(result.warnings.git_plaintext_store);
}

test "remote authentication uses a cached noninteractive HTTPS credential helper" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "home", .default_dir);
    var home = try tmp.dir.openDir(io, "home", .{});
    defer home.close(io);
    try home.writeFile(io, .{
        .sub_path = ".git-credentials",
        .data = "https://alice:CACHED-HTTPS-CREDENTIAL-CANARY@example.invalid\n",
    });
    const home_root = try tmp.dir.realPathFileAlloc(io, "home", std.testing.allocator);
    defer std.testing.allocator.free(home_root);

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", home_root);
    try parent.put("DISPLAY", ":99");
    try parent.put("BROWSER", "GUI-CANARY");
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .background);
    defer environment.deinit();
    try std.testing.expect(environment.map.get("DISPLAY") == null);
    try std.testing.expect(environment.map.get("BROWSER") == null);

    const argv = [_][]const u8{
        "sh",
        "-c",
        "printf 'protocol=https\\nhost=example.invalid\\n\\n' | git -c credential.interactive=false -c credential.helper=store credential fill",
    };
    var command = runSensitiveRemoteCommand(
        std.testing.allocator,
        io,
        tmp.dir,
        &environment.map,
        .{},
        &argv,
    );
    defer command.deinit();
    try std.testing.expect(commandFailure(&command, false, .read_only) == null);
    const output = switch (command) {
        .completed => |*result| result.stdout.bytes(),
        else => return error.ExpectedCachedCredential,
    };
    try std.testing.expect(std.mem.indexOf(u8, output, "username=alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "password=CACHED-HTTPS-CREDENTIAL-CANARY") != null);
}

test "remote authentication descriptor cwd survives repository path replacement" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);

    const work_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(work_root);
    var root = try root_capability.RootCapability.openCanonical(work_root);
    defer root.deinit();
    try tmp.dir.rename("work", tmp.dir, "pinned-work", io);
    try tmp.dir.createDir(io, "work", .default_dir);
    var replacement = try tmp.dir.openDir(io, "work", .{});
    defer replacement.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, replacement);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "https://alice:REPLACEMENT-CANARY@127.0.0.1:1/repo.git" }, replacement);

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .background);
    defer environment.deinit();
    const result = runOperation(std.testing.allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .fetch = .{ .remote = "origin" } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .ok = .completed }, result.outcome);
}

test "remote URL userinfo is rejected before background authentication network access" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "https://alice:REMOTE-URL-NETWORK-CANARY@127.0.0.1:1/owner/repo.git" }, work);

    const work_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(work_root);
    var root = try root_capability.RootCapability.openCanonical(work_root);
    defer root.deinit();
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .background);
    defer environment.deinit();

    const result = runOperation(std.testing.allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .kind = .{ .fetch = .{ .remote = "origin" } },
    });
    try std.testing.expectEqual(
        RemoteOperationOutcome{ .failed = .http_userinfo_rejected },
        result.outcome,
    );
}

test "foreground remote environment omits credential-bearing proxies" {
    const allocator = std.testing.allocator;
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();

    try parent.put("HTTP_PROXY", "http://alice:PROXY-CANARY@proxy.test:8080");
    try parent.put("https_proxy", "bob:SECOND-CANARY@proxy.test:8081");
    try parent.put("HTTPS_PROXY", "http://proxy.test/path@not-userinfo");
    try parent.put("ALL_PROXY", "socks5://proxy.test:1080");
    try parent.put("NO_PROXY", "localhost,127.0.0.1");
    try parent.put("no_proxy", "alice:NO-PROXY-CANARY@proxy.test");

    var owned = try buildRemoteEnvironment(allocator, &parent, .foreground);
    defer owned.deinit();
    try std.testing.expect(owned.warnings.proxy_credentials_omitted);
    try std.testing.expect(owned.map.get("HTTP_PROXY") == null);
    try std.testing.expect(owned.map.get("https_proxy") == null);
    try std.testing.expectEqualStrings("http://proxy.test/path@not-userinfo", owned.map.get("HTTPS_PROXY").?);
    try std.testing.expectEqualStrings("socks5://proxy.test:1080", owned.map.get("ALL_PROXY").?);
    try std.testing.expectEqualStrings("localhost,127.0.0.1", owned.map.get("NO_PROXY").?);
    try std.testing.expect(owned.map.get("no_proxy") == null);
    for (owned.map.values()) |value| {
        try std.testing.expect(std.mem.indexOf(u8, value, "alice") == null);
        try std.testing.expect(std.mem.indexOf(u8, value, "PROXY-CANARY") == null);
        try std.testing.expect(std.mem.indexOf(u8, value, "SECOND-CANARY") == null);
        try std.testing.expect(std.mem.indexOf(u8, value, "NO-PROXY-CANARY") == null);
    }
}

fn exerciseForegroundRemoteEnvironmentAllocationFailure(
    allocator: std.mem.Allocator,
    parent: *const std.process.Environ.Map,
) !void {
    var prepared = try prepareForegroundPush(
        allocator,
        parent,
        .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = "0123456789abcdef",
        },
        .{ .git_plaintext_store = true },
    );
    defer prepared.deinit(allocator);
    try std.testing.expectEqualStrings("1", prepared.environment.map.get("GCM_INTERACTIVE").?);
    try std.testing.expect(prepared.environment.warnings.git_plaintext_store);
    try std.testing.expect(prepared.environment.warnings.proxy_credentials_omitted);
    try std.testing.expect(prepared.environment.map.get("HTTPS_PROXY") == null);
    try std.testing.expectEqualStrings("origin", prepared.argv[11]);
    try std.testing.expectEqualStrings("0123456789abcdef:refs/heads/main", prepared.argv[12]);
}

test "foreground remote environment releases partial construction on allocation failure" {
    const allocator = std.testing.allocator;
    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", "/home/test");
    try parent.put("LC_ALL", "C.UTF-8");
    try parent.put("TERM", "xterm-256color");
    try parent.put("SSH_AUTH_SOCK", "/run/agent.sock");
    try parent.put("HTTPS_PROXY", "http://alice:PROXY-CANARY@proxy.test:8080");
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseForegroundRemoteEnvironmentAllocationFailure,
        .{&parent},
    );
}

test "remote foreground push inspection rejects stale oid before admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", "." }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", repo_root);
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .inspection);
    defer environment.deinit();
    var root = try root_capability.RootCapability.openCanonical(repo_root);
    defer root.deinit();
    const result = inspectForegroundPush(std.testing.allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .push = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = "not-the-current-oid",
        },
    });
    try std.testing.expectEqual(ForegroundPushInspectionOutcome.oid_changed, result.outcome);
}

test "remote foreground push inspection rejects a missing remote" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);
    const oid = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(oid);

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", repo_root);
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .inspection);
    defer environment.deinit();
    var root = try root_capability.RootCapability.openCanonical(repo_root);
    defer root.deinit();
    const result = inspectForegroundPush(std.testing.allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .push = .{
            .branch = "main",
            .remote = "missing",
            .remote_branch = "main",
            .oid = trimLineEnd(oid),
        },
    });
    try std.testing.expectEqual(ForegroundPushInspectionOutcome{ .failed = .failed }, result.outcome);
}

test "remote foreground push inspection accepts a local bare remote" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);
    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    const oid = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(oid);

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", repo_root);
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .inspection);
    defer environment.deinit();
    var root = try root_capability.RootCapability.openCanonical(repo_root);
    defer root.deinit();
    const result = inspectForegroundPush(std.testing.allocator, io, .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .push = .{
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = trimLineEnd(oid),
        },
    });
    try std.testing.expectEqual(ForegroundPushInspectionOutcome.ready, result.outcome);

    const config_result = try std.process.run(std.testing.allocator, io, .{
        .argv = &[_][]const u8{ "git", "config", "--get", "branch.main.remote" },
        .cwd = .{ .dir = work },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, config_result);
    try std.testing.expect(config_result.term == .exited and config_result.term.exited != 0);
}

test "remote push sends the saved oid after the current branch moves" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Case = enum { background_upstream, background_set_upstream, foreground_set_upstream };
    for ([_]Case{ .background_upstream, .background_set_upstream, .foreground_set_upstream }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
        try tmp.dir.createDir(io, "work", .default_dir);
        var work = try tmp.dir.openDir(io, "work", .{});
        defer work.close(io);
        var remote = try tmp.dir.openDir(io, "remote.git", .{});
        defer remote.close(io);
        try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
        try runTestGit(io, &.{ "git", "remote", "add", "origin", "../remote.git" }, work);
        try work.writeFile(io, .{ .sub_path = "guard", .data = "committed\n" });
        try runTestGit(io, &.{ "git", "add", "guard" }, work);
        try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "A" }, work);
        try runTestGit(io, &.{ "git", "tag", "main" }, work);
        const oid_a = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "HEAD" });
        defer allocator.free(oid_a);
        const oid_b = try gitOutputAlloc(io, work, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "B" });
        defer allocator.free(oid_b);
        try runTestGit(io, &.{ "git", "update-ref", "refs/heads/next", trimLineEnd(oid_b) }, work);
        try work.writeFile(io, .{ .sub_path = "guard", .data = "staged\n" });
        try runTestGit(io, &.{ "git", "add", "guard" }, work);
        try work.writeFile(io, .{ .sub_path = "guard", .data = "worktree\n" });
        if (case == .background_upstream) {
            try runTestGit(io, &.{ "git", "config", "branch.main.remote", "origin" }, work);
            try runTestGit(io, &.{ "git", "config", "branch.main.merge", "refs/heads/main" }, work);
        }

        // Advance A to B only when the actual push child starts, after inspection.
        try tmp.dir.createDir(io, "bin", .default_dir);
        try writeExecutableRemoteTestScript(
            io,
            tmp.dir,
            "bin/git",
            "#!/bin/sh\n" ++
                "for arg do\n" ++
                "  if [ \"$arg\" = push ]; then\n" ++
                "    /usr/bin/git update-ref refs/heads/main \"$(/usr/bin/git rev-parse refs/heads/next)\" || exit 1\n" ++
                "    break\n" ++
                "  fi\n" ++
                "done\n" ++
                "exec /usr/bin/git \"$@\"\n",
        );
        const bin = try tmp.dir.realPathFileAlloc(io, "bin", allocator);
        defer allocator.free(bin);
        const path = try std.fmt.allocPrint(allocator, "{s}:/usr/bin:/bin", .{bin});
        defer allocator.free(path);
        const repo_root = try tmp.dir.realPathFileAlloc(io, "work", allocator);
        defer allocator.free(repo_root);
        var parent = std.process.Environ.Map.init(allocator);
        defer parent.deinit();
        try parent.put("PATH", path);
        try parent.put("HOME", repo_root);
        // Executable lookup uses the Io environment, independently of child env.
        const block = try parent.createPosixBlock(allocator, .{});
        defer block.deinit(allocator);
        var threaded = std.Io.Threaded.init(allocator, .{ .environ = .{ .block = block } });
        defer threaded.deinit();
        const push_io = threaded.io();
        var environment = try buildRemoteEnvironment(allocator, &parent, .background);
        defer environment.deinit();
        var root = try root_capability.RootCapability.openCanonical(repo_root);
        defer root.deinit();
        const push: PushRequest = .{
            .mode = if (case == .background_upstream) .upstream else .set_upstream,
            .branch = "main",
            .remote = "origin",
            .remote_branch = "main",
            .oid = trimLineEnd(oid_a),
        };
        if (case == .foreground_set_upstream) {
            const inspection = inspectForegroundPush(allocator, push_io, .{ .root = &root, .environment = &environment, .control = .{}, .push = push });
            try std.testing.expectEqual(ForegroundPushInspectionOutcome.ready, inspection.outcome);
            var prepared = try prepareForegroundPush(allocator, &parent, push, inspection.warnings);
            defer prepared.deinit(allocator);
            const child = try std.process.run(allocator, push_io, .{ .argv = &prepared.argv, .cwd = .{ .dir = root.dir() }, .environ_map = &prepared.environment.map });
            defer freeRunResult(allocator, child);
            try std.testing.expect(termExited(child.term, 0));
            var local = try buildRemoteEnvironment(allocator, &parent, .local_finalizer);
            defer local.deinit();
            try std.testing.expectEqual(PushUpstreamFinalizeOutcome.oid_changed, finalizePushUpstream(allocator, push_io, .{
                .root = &root,
                .environment = &local,
                .control = .{},
                .branch = push.branch,
                .remote = push.remote,
                .remote_branch = push.remote_branch,
                .oid = push.oid,
            }));
        } else {
            const result = runOperation(allocator, push_io, .{ .root = &root, .environment = &environment, .control = .{}, .kind = .{ .push = push } });
            const expected: RemoteSuccess = if (case == .background_upstream) .completed else .push_tracking_incomplete;
            try std.testing.expectEqual(RemoteOperationOutcome{ .ok = expected }, result.outcome);
        }
        const sent = try gitOutputAlloc(io, remote, &.{ "git", "rev-parse", "refs/heads/main" });
        defer allocator.free(sent);
        try std.testing.expectEqualStrings(oid_a, sent);
        const head = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "HEAD" });
        defer allocator.free(head);
        try std.testing.expectEqualStrings(oid_b, head);
        const branch = try gitOutputAlloc(io, work, &.{ "git", "symbolic-ref", "HEAD" });
        defer allocator.free(branch);
        try std.testing.expectEqualStrings("refs/heads/main\n", branch);
        const index = try gitOutputAlloc(io, work, &.{ "git", "show", ":guard" });
        defer allocator.free(index);
        try std.testing.expectEqualStrings("staged\n", index);
        const file = try work.readFileAlloc(io, "guard", allocator, .limited(1024));
        defer allocator.free(file);
        try std.testing.expectEqualStrings("worktree\n", file);
        if (case == .background_upstream) {
            const config = try gitOutputAlloc(io, work, &.{ "git", "config", "--get-regexp", "^branch\\.main\\." });
            defer allocator.free(config);
            try std.testing.expectEqualStrings("branch.main.remote origin\nbranch.main.merge refs/heads/main\n", config);
        } else {
            try runTestGitFailure(io, &.{ "git", "config", "--get-regexp", "^branch\\.main\\." }, work);
        }
    }
}

test "remote upstream finalization configures local tracking after fixed oid push" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    const remote_root = try tmp.dir.realPathFileAlloc(io, "remote.git", std.testing.allocator);
    defer std.testing.allocator.free(remote_root);
    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", std.testing.allocator);
    defer std.testing.allocator.free(repo_root);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "remote", "add", "origin", remote_root }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);
    try runTestGit(io, &.{ "git", "switch", "-c", "feature/topic" }, work);
    try work.writeFile(io, .{ .sub_path = "FEATURE.md", .data = "feature\n" });
    try runTestGit(io, &.{ "git", "add", "FEATURE.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "feature" }, work);

    const oid = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer std.testing.allocator.free(oid);

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", repo_root);
    var environment = try buildRemoteEnvironment(std.testing.allocator, &parent, .local_finalizer);
    defer environment.deinit();
    var root = try root_capability.RootCapability.openCanonical(repo_root);
    defer root.deinit();
    const request: PushUpstreamFinalizeRequest = .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .branch = "feature/topic",
        .remote = "origin",
        .remote_branch = "feature/topic",
        .oid = trimLineEnd(oid),
    };
    var background = try buildRemoteEnvironment(std.testing.allocator, &parent, .background);
    defer background.deinit();
    const pushed = runOperation(std.testing.allocator, io, .{
        .root = &root,
        .environment = &background,
        .control = .{},
        .kind = .{ .push = .{ .mode = .set_upstream, .branch = request.branch, .remote = request.remote, .remote_branch = request.remote_branch, .oid = request.oid } },
    });
    try std.testing.expectEqual(RemoteOperationOutcome{ .ok = .completed }, pushed.outcome);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.already_configured,
        finalizePushUpstream(std.testing.allocator, io, request),
    );

    const remote_oid = try gitOutputAlloc(io, work, &.{ "git", "--git-dir", remote_root, "rev-parse", "--verify", "refs/heads/feature/topic" });
    defer std.testing.allocator.free(remote_oid);
    try std.testing.expectEqualStrings(trimLineEnd(oid), trimLineEnd(remote_oid));

    const upstream_remote = try gitOutputAlloc(io, work, &.{ "git", "config", "--get", "branch.feature/topic.remote" });
    defer std.testing.allocator.free(upstream_remote);
    try std.testing.expectEqualStrings("origin", trimLineEnd(upstream_remote));

    const upstream_merge = try gitOutputAlloc(io, work, &.{ "git", "config", "--get", "branch.feature/topic.merge" });
    defer std.testing.allocator.free(upstream_merge);
    try std.testing.expectEqualStrings("refs/heads/feature/topic", trimLineEnd(upstream_merge));
}

test "remote upstream finalization has conflict-safe typed terminals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(repo_root);
    const oid_bytes = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer allocator.free(oid_bytes);
    const oid = trimLineEnd(oid_bytes);

    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", repo_root);
    var environment = try buildRemoteEnvironment(allocator, &parent, .local_finalizer);
    defer environment.deinit();
    var root = try root_capability.RootCapability.openCanonical(repo_root);
    defer root.deinit();
    var request: PushUpstreamFinalizeRequest = .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .branch = "main",
        .remote = "origin",
        .remote_branch = "main",
        .oid = oid,
    };

    try runTestGit(io, &.{ "git", "switch", "-c", "other" }, work);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.branch_changed,
        finalizePushUpstream(allocator, io, request),
    );
    try runTestGit(io, &.{ "git", "switch", "main" }, work);

    request.oid = "0000000000000000000000000000000000000000";
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.oid_changed,
        finalizePushUpstream(allocator, io, request),
    );
    request.oid = oid;

    try runTestGit(io, &.{ "git", "switch", "--detach" }, work);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.context_changed,
        finalizePushUpstream(allocator, io, request),
    );
    try runTestGit(io, &.{ "git", "switch", "main" }, work);

    try runTestGit(io, &.{ "git", "config", "--local", "--add", "branch.main.remote", "origin" }, work);
    try runTestGit(io, &.{ "git", "config", "--local", "--add", "branch.main.remote", "origin" }, work);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.config_verification_failed,
        finalizePushUpstream(allocator, io, request),
    );
    try runTestGit(io, &.{ "git", "config", "--local", "--unset-all", "branch.main.remote" }, work);

    try runTestGit(io, &.{ "git", "config", "--local", "branch.main.remote", "other" }, work);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.upstream_conflict,
        finalizePushUpstream(allocator, io, request),
    );
    try runTestGit(io, &.{ "git", "config", "--local", "--unset-all", "branch.main.remote" }, work);

    var lock = try work.createFile(io, ".git/config.lock", .{ .exclusive = true });
    lock.close(io);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.config_write_failed,
        finalizePushUpstream(allocator, io, request),
    );
    try work.deleteFile(io, ".git/config.lock");

    var canceled_generation: std.atomic.Value(u64) = .init(7);
    request.control = .{ .cancellation = .{
        .canceled_generation = &canceled_generation,
        .generation = 7,
    } };
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.tracking_unknown,
        finalizePushUpstream(allocator, io, request),
    );
    request.control = .{};

    try runTestGit(io, &.{ "git", "config", "--local", "branch.autoSetupRebase", "remote" }, work);
    try runTestGit(io, &.{ "git", "config", "--local", "branch.main.rebase", "false" }, work);
    request.remote = ".";
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.configured,
        finalizePushUpstream(allocator, io, request),
    );
    const configured_remote = try gitOutputAlloc(io, work, &.{ "git", "config", "--get", "branch.main.remote" });
    defer allocator.free(configured_remote);
    try std.testing.expectEqualStrings(".", trimLineEnd(configured_remote));
    const configured_rebase = try gitOutputAlloc(io, work, &.{ "git", "config", "--bool", "--get", "branch.main.rebase" });
    defer allocator.free(configured_rebase);
    try std.testing.expectEqualStrings("true", trimLineEnd(configured_rebase));
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.already_configured,
        finalizePushUpstream(allocator, io, request),
    );
    try runTestGit(io, &.{ "git", "config", "--local", "branch.main.rebase", "false" }, work);
    try std.testing.expectEqual(
        PushUpstreamFinalizeOutcome.upstream_conflict,
        finalizePushUpstream(allocator, io, request),
    );
    const conflicting_rebase = try gitOutputAlloc(io, work, &.{ "git", "config", "--bool", "--get", "branch.main.rebase" });
    defer allocator.free(conflicting_rebase);
    try std.testing.expectEqualStrings("false", trimLineEnd(conflicting_rebase));
}

const UpstreamFinalizerFault = enum {
    second_write,
    rebase_write,
    postcondition_mismatch,
};

fn injectUpstreamFinalizerFault(
    io: std.Io,
    work: std.Io.Dir,
    fault: UpstreamFinalizerFault,
) !void {
    for (0..5_000) |_| {
        const config = work.readFileAlloc(io, ".git/config", std.testing.allocator, .limited(64 * 1024)) catch {
            try io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        const has_remote = std.mem.indexOf(u8, config, "remote = origin") != null;
        const has_merge = std.mem.indexOf(u8, config, "merge = refs/heads/main") != null;
        const has_rebase_true = std.mem.indexOf(u8, config, "rebase = true") != null;
        std.testing.allocator.free(config);

        const ready = switch (fault) {
            .second_write => has_remote and !has_merge,
            .rebase_write => has_remote and has_merge,
            .postcondition_mismatch => has_remote and has_merge and has_rebase_true,
        };
        if (!ready) {
            try io.sleep(.fromMilliseconds(1), .awake);
            continue;
        }

        switch (fault) {
            .second_write, .rebase_write => {
                var lock = work.createFile(io, ".git/config.lock", .{ .exclusive = true }) catch {
                    try io.sleep(.fromMilliseconds(1), .awake);
                    continue;
                };
                lock.close(io);
                return;
            },
            .postcondition_mismatch => {
                runTestGit(io, &.{ "git", "config", "--local", "branch.main.rebase", "false" }, work) catch {
                    try io.sleep(.fromMilliseconds(1), .awake);
                    continue;
                };
                return;
            },
        }
    }
    return error.FinalizerFaultInjectionMissed;
}

fn exerciseUpstreamFinalizerFault(
    io: std.Io,
    tmp: std.Io.Dir,
    fault: UpstreamFinalizerFault,
) !void {
    const allocator = std.testing.allocator;
    const case_name = @tagName(fault);
    try tmp.createDir(io, case_name, .default_dir);
    var fixture = try tmp.openDir(io, case_name, .{});
    defer fixture.close(io);
    try fixture.createDir(io, "work", .default_dir);
    var work = try fixture.openDir(io, "work", .{});
    defer work.close(io);

    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runTestGit(io, &.{ "git", "add", "README.md" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    switch (fault) {
        .second_write => {},
        .rebase_write, .postcondition_mismatch => {
            try runTestGit(io, &.{ "git", "config", "--local", "branch.autoSetupRebase", "remote" }, work);
            try runTestGit(io, &.{ "git", "config", "--local", "branch.main.rebase", "false" }, work);
        },
    }

    const repo_root = try fixture.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(repo_root);
    const oid_bytes = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    defer allocator.free(oid_bytes);

    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", repo_root);
    var environment = try buildRemoteEnvironment(allocator, &parent, .local_finalizer);
    defer environment.deinit();
    var root = try root_capability.RootCapability.openCanonical(repo_root);
    defer root.deinit();
    const request: PushUpstreamFinalizeRequest = .{
        .root = &root,
        .environment = &environment,
        .control = .{},
        .branch = "main",
        .remote = "origin",
        .remote_branch = "main",
        .oid = trimLineEnd(oid_bytes),
    };

    const expected: PushUpstreamFinalizeOutcome = switch (fault) {
        .second_write, .rebase_write => .config_write_failed,
        .postcondition_mismatch => .config_verification_failed,
    };
    var fault_future = try io.concurrent(injectUpstreamFinalizerFault, .{ io, work, fault });
    defer _ = fault_future.cancel(io) catch {};
    const outcome = finalizePushUpstream(allocator, io, request);
    try fault_future.await(io);
    try std.testing.expectEqual(expected, outcome);

    const configured_remote = try gitOutputAlloc(io, work, &.{ "git", "config", "--get", "branch.main.remote" });
    defer allocator.free(configured_remote);
    try std.testing.expectEqualStrings("origin", trimLineEnd(configured_remote));
    switch (fault) {
        .second_write => try runTestGitFailure(io, &.{ "git", "config", "--get", "branch.main.merge" }, work),
        .rebase_write => {
            const configured_merge = try gitOutputAlloc(io, work, &.{ "git", "config", "--get", "branch.main.merge" });
            defer allocator.free(configured_merge);
            try std.testing.expectEqualStrings("refs/heads/main", trimLineEnd(configured_merge));
            const configured_rebase = try gitOutputAlloc(io, work, &.{ "git", "config", "--bool", "--get", "branch.main.rebase" });
            defer allocator.free(configured_rebase);
            try std.testing.expectEqualStrings("false", trimLineEnd(configured_rebase));
        },
        .postcondition_mismatch => {
            const configured_merge = try gitOutputAlloc(io, work, &.{ "git", "config", "--get", "branch.main.merge" });
            defer allocator.free(configured_merge);
            try std.testing.expectEqualStrings("refs/heads/main", trimLineEnd(configured_merge));
            const configured_rebase = try gitOutputAlloc(io, work, &.{ "git", "config", "--bool", "--get", "branch.main.rebase" });
            defer allocator.free(configured_rebase);
            try std.testing.expectEqualStrings("false", trimLineEnd(configured_rebase));
        },
    }
}

test "remote upstream finalization reports later write and postcondition faults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (std.meta.tags(UpstreamFinalizerFault)) |fault| {
        try exerciseUpstreamFinalizerFault(std.testing.io, tmp.dir, fault);
    }
}

fn runTestGit(io: std.Io, argv: []const []const u8, cwd: std.Io.Dir) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, result);

    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

fn runTestGitFailure(io: std.Io, argv: []const []const u8, cwd: std.Io.Dir) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, result);
    switch (result.term) {
        .exited => |code| if (code != 0) return,
        else => {},
    }
    return error.ExpectedGitCommandFailure;
}

fn gitOutputAlloc(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    errdefer freeRunResult(std.testing.allocator, result);
    switch (result.term) {
        .exited => |code| if (code == 0) {
            std.testing.allocator.free(result.stderr);
            return result.stdout;
        },
        else => {},
    }
    freeRunResult(std.testing.allocator, result);
    return error.GitCommandFailed;
}

test "remote push failure phase preserves actual effects" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Case = enum { normal, overflow, signal, cancel, timeout, preflight_overflow, spawn_failure, pre_cancel, pre_timeout, after_fetch_spawn };
    for ([_]Case{ .normal, .overflow, .signal, .cancel, .timeout, .preflight_overflow, .spawn_failure, .pre_cancel, .pre_timeout, .after_fetch_spawn }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try runTestGit(io, &.{ "git", "init", "--bare", "remote.git" }, tmp.dir);
        try tmp.dir.createDir(io, "work", .default_dir);
        var work = try tmp.dir.openDir(io, "work", .{});
        defer work.close(io);
        var remote = try tmp.dir.openDir(io, "remote.git", .{});
        defer remote.close(io);
        try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
        try runTestGit(io, &.{ "git", "remote", "add", "origin", "../remote.git" }, work);
        try work.writeFile(io, .{ .sub_path = "guard", .data = "committed\n" });
        try runTestGit(io, &.{ "git", "add", "guard" }, work);
        try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "O" }, work);
        try runTestGit(io, &.{ "git", "push", "origin", "HEAD:refs/heads/main" }, work);
        const oid_o = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "HEAD" });
        defer allocator.free(oid_o);
        try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "A" }, work);
        const oid_a = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "HEAD" });
        defer allocator.free(oid_a);
        if (case == .after_fetch_spawn) {
            try runTestGit(io, &.{ "git", "push", "origin", "HEAD:refs/heads/main" }, work);
            try runTestGit(io, &.{ "git", "update-ref", "refs/heads/main", trimLineEnd(oid_o) }, work);
            try runTestGit(io, &.{ "git", "update-ref", "refs/remotes/origin/main", trimLineEnd(oid_o) }, work);
            try runTestGit(io, &.{ "git", "config", "branch.main.remote", "origin" }, work);
            try runTestGit(io, &.{ "git", "config", "branch.main.merge", "refs/heads/main" }, work);
        } else {
            try work.writeFile(io, .{ .sub_path = "guard", .data = "staged\n" });
            try runTestGit(io, &.{ "git", "add", "guard" }, work);
            try work.writeFile(io, .{ .sub_path = "guard", .data = "worktree\n" });
        }
        try tmp.dir.createDir(io, "bin", .default_dir);
        const fault = switch (case) {
            .spawn_failure, .after_fetch_spawn => "/bin/rm -- \"$0\" || exit 97\n",
            .cancel, .timeout => "printf pushed > pushed.marker\n/bin/sleep 10\n",
            .overflow, .preflight_overflow => "/usr/bin/head -c 300000 /dev/zero\n",
            .signal => "kill -TERM $$\n",
            else => "",
        };
        const trigger = if (case == .preflight_overflow) "remote" else if (case == .spawn_failure) "rev-parse" else if (case == .after_fetch_spawn) "fetch" else "push";
        const script = try std.fmt.allocPrint(allocator, "#!/bin/sh\nfor arg do\n if [ \"$arg\" = {s} ]; then\n /usr/bin/git \"$@\" || exit 1\n {s}exit 0\n fi\ndone\nexec /usr/bin/git \"$@\"\n", .{ trigger, fault });
        defer allocator.free(script);
        try writeExecutableRemoteTestScript(io, tmp.dir, "bin/git", script);
        const bin = try tmp.dir.realPathFileAlloc(io, "bin", allocator);
        defer allocator.free(bin);
        const repo_root = try tmp.dir.realPathFileAlloc(io, "work", allocator);
        defer allocator.free(repo_root);
        var parent = std.process.Environ.Map.init(allocator);
        defer parent.deinit();
        try parent.put("PATH", bin);
        try parent.put("HOME", repo_root);
        const block = try parent.createPosixBlock(allocator, .{});
        defer block.deinit(allocator);
        var threaded = std.Io.Threaded.init(allocator, .{ .environ = .{ .block = block } });
        defer threaded.deinit();
        var environment = try buildRemoteEnvironment(allocator, &parent, .background);
        defer environment.deinit();
        var canceled_generation: std.atomic.Value(u64) = .init(if (case == .pre_cancel) 23 else 0);
        var cancel_future: ?std.Io.Future(std.Io.Cancelable!void) = if (case == .cancel)
            try io.concurrent(cancelRemoteAfterPushMarker, .{ io, work, &canceled_generation })
        else
            null;
        defer if (cancel_future) |*future| {
            _ = future.cancel(io) catch {};
        };
        const control: process_runner.ProcessControl = .{
            .cancellation = .{ .canceled_generation = &canceled_generation, .generation = 23 },
            .deadline = if (case == .timeout or case == .pre_timeout)
                std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(if (case == .pre_timeout) -1 else 3000), .clock = .awake })
            else
                null,
        };
        var root = try root_capability.RootCapability.openCanonical(repo_root);
        defer root.deinit();
        const result = runOperation(allocator, threaded.io(), .{
            .root = &root,
            .environment = &environment,
            .control = control,
            .kind = if (case == .after_fetch_spawn) .{ .pull_refresh_ff_only = .{ .branch = "main", .remote = "origin", .remote_branch = "main", .upstream_ref = "refs/remotes/origin/main", .oid = trimLineEnd(oid_o) } } else .{ .push = .{ .branch = "main", .remote = "origin", .remote_branch = "main", .oid = trimLineEnd(oid_a) } },
        });
        if (cancel_future) |*future| try future.await(io);
        if (case == .spawn_failure or case == .after_fetch_spawn) {
            try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "bin/git", .{}));
        }
        const expected: RemoteOperationOutcome = switch (case) {
            .normal => .{ .ok = .completed },
            .overflow, .signal, .after_fetch_spawn => .{ .failed = .outcome_unknown },
            .cancel => .{ .failed = .canceled_outcome_unknown },
            .timeout => .{ .failed = .timed_out_outcome_unknown },
            .preflight_overflow => .{ .failed = .failed },
            .spawn_failure => .{ .failed = .spawn_failed },
            .pre_cancel => .{ .failed = .canceled },
            .pre_timeout => .{ .failed = .timed_out },
        };
        try std.testing.expectEqual(expected, result.outcome);
        const updated = switch (case) {
            .preflight_overflow, .spawn_failure, .pre_cancel, .pre_timeout => false,
            else => true,
        };
        const sent = try gitOutputAlloc(io, remote, &.{ "git", "rev-parse", "refs/heads/main" });
        defer allocator.free(sent);
        try std.testing.expectEqualStrings(if (updated) oid_a else oid_o, sent);
        const head = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "HEAD" });
        defer allocator.free(head);
        try std.testing.expectEqualStrings(if (case == .after_fetch_spawn) oid_o else oid_a, head);
        const index = try gitOutputAlloc(io, work, &.{ "git", "show", ":guard" });
        defer allocator.free(index);
        try std.testing.expectEqualStrings(if (case == .after_fetch_spawn) "committed\n" else "staged\n", index);
        const file = try work.readFileAlloc(io, "guard", allocator, .limited(1024));
        defer allocator.free(file);
        try std.testing.expectEqualStrings(if (case == .after_fetch_spawn) "committed\n" else "worktree\n", file);
        if (case == .after_fetch_spawn) {
            const fetched = try gitOutputAlloc(io, work, &.{ "git", "rev-parse", "refs/remotes/origin/main" });
            defer allocator.free(fetched);
            try std.testing.expectEqualStrings(oid_a, fetched);
        }
        if (case == .cancel or case == .timeout) try work.access(io, "pushed.marker", .{});
    }
}

fn cancelRemoteAfterPushMarker(io: std.Io, work: std.Io.Dir, generation: *std.atomic.Value(u64)) std.Io.Cancelable!void {
    // Only cancel after real Git reported success; bounded polling avoids a hanging test.
    for (0..500) |_| {
        if (work.access(io, "pushed.marker", .{})) |_| {
            generation.store(23, .release);
            return;
        } else |_| {}
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    generation.store(23, .release);
}
