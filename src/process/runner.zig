const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    EmptyArgv,
    StreamTooLong,
    StdoutLimitExceeded,
    StderrLimitExceeded,
    WriteFailed,
} || std.process.SpawnError || std.process.Child.WaitError || std.Io.ConcurrentError || std.Io.File.MultiReader.UnendingError || std.Io.Timeout.Error || std.Io.File.Writer.Error;

pub const Options = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    /// Complete child environment. Non-null replaces, rather than augments,
    /// the inherited process environment.
    environ_map: ?*const std.process.Environ.Map = null,
    stdin: []const u8 = &.{},
    stdout_limit: std.Io.Limit = .unlimited,
    stderr_limit: std.Io.Limit = .unlimited,
};

/// Selects whether captured bytes have ordinary or zeroizing ownership.
pub const CaptureMode = enum {
    ordinary,
    sensitive,
};

/// A generation-scoped cancellation signal borrowed for the duration of a
/// controlled process run. Generation zero is reserved as "not canceled".
pub const CancellationView = struct {
    canceled_generation: *const std.atomic.Value(u64),
    generation: u64,

    pub fn requested(self: CancellationView) bool {
        return self.generation != 0 and self.canceled_generation.load(.acquire) == self.generation;
    }
};

/// Bounds one process run with an operation-wide absolute deadline and/or a
/// generation-scoped cancellation view.
pub const ProcessControl = struct {
    deadline: ?std.Io.Clock.Timestamp = null,
    cancellation: ?CancellationView = null,
};

/// Captured bytes whose entire allocation is securely cleared before free.
///
/// The storage is represented as a pointer and scalar lengths so generic
/// debug formatting cannot reflect the captured contents.
pub const SensitiveBytes = struct {
    allocator: std.mem.Allocator,
    storage: ?[*]u8,
    len: usize,
    capacity: usize,

    pub fn bytes(self: *const SensitiveBytes) []const u8 {
        const ptr = self.storage orelse return &.{};
        return ptr[0..self.len];
    }

    pub fn deinit(self: *SensitiveBytes) void {
        if (self.storage) |ptr| {
            const allocation = ptr[0..self.capacity];
            std.crypto.secureZero(u8, allocation);
            // Allocator.free poisons memory before calling the allocator
            // vtable. Use rawFree so the final observable write is the secure
            // zeroization above.
            self.allocator.rawFree(allocation, .of(u8), @returnAddress());
        }
        self.storage = null;
        self.len = 0;
        self.capacity = 0;
    }
};

pub const SensitiveResult = struct {
    term: std.process.Child.Term,
    stdout: SensitiveBytes,
    stderr: SensitiveBytes,

    pub fn deinit(self: *SensitiveResult) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }
};

pub const CapturedResult = union(CaptureMode) {
    ordinary: Result,
    sensitive: SensitiveResult,

    pub fn deinit(self: *CapturedResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ordinary => |result| result.deinit(allocator),
            .sensitive => |*result| result.deinit(),
        }
    }
};

pub const ControlledFailure = union(enum) {
    empty_argv,
    unsupported_process_control,
    spawn: anyerror,
    stdin_start: std.Io.ConcurrentError,
    stdin: anyerror,
    control_start: std.Io.ConcurrentError,
    capture: anyerror,
    terminate: anyerror,
    wait: anyerror,

    pub fn errorName(self: ControlledFailure) []const u8 {
        return switch (self) {
            .empty_argv => "EmptyArgv",
            .unsupported_process_control => "UnsupportedProcessControl",
            inline .spawn, .stdin_start, .stdin, .control_start, .capture, .terminate, .wait => |err| @errorName(err),
        };
    }
};

/// Whether a child was spawned before cancellation or timeout was accepted.
pub const SpawnPhase = enum { not_started, started };

/// A controlled run returns captured output only when the direct child
/// completes before cancellation or timeout is accepted.
pub const ControlledResult = union(enum) {
    completed: CapturedResult,
    canceled: SpawnPhase,
    timed_out: SpawnPhase,
    failed: ControlledFailure,

    pub fn deinit(self: *ControlledResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed => |*result| result.deinit(allocator),
            .canceled, .timed_out, .failed => {},
        }
        self.* = .{ .failed = .empty_argv };
    }
};

pub const Result = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const StdinFailure = struct {
    err: anyerror,
    result: Result,

    pub fn takeResult(self: *StdinFailure) Result {
        const result = self.result;
        self.result.stdout = &.{};
        self.result.stderr = &.{};
        return result;
    }
};

pub const Failure = union(enum) {
    empty_argv,
    spawn: anyerror,
    stdin_start: std.Io.ConcurrentError,
    stdin: StdinFailure,
    capture: anyerror,
    wait: anyerror,

    pub fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .stdin => |*failure| failure.result.deinit(allocator),
            else => {},
        }
        self.* = .empty_argv;
    }

    pub fn errorName(self: Failure) []const u8 {
        return switch (self) {
            .empty_argv => "EmptyArgv",
            .stdin => |failure| @errorName(failure.err),
            inline .spawn, .stdin_start, .capture, .wait => |err| @errorName(err),
        };
    }

    pub fn toError(self: Failure) Error {
        return switch (self) {
            .empty_argv => error.EmptyArgv,
            .stdin => |failure| @errorCast(failure.err),
            inline .spawn, .stdin_start, .capture, .wait => |err| @errorCast(err),
        };
    }
};

pub const DetailedResult = union(enum) {
    ok: Result,
    failed: Failure,

    pub fn deinit(self: *DetailedResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |result| result.deinit(allocator),
            .failed => |*failure| failure.deinit(allocator),
        }
        self.* = .{ .failed = .empty_argv };
    }
};

/// Captured process result which preserves which bounded output stream crossed
/// its limit. Overflow never exposes partial bytes; all other lifecycle and IO
/// failures retain the existing detailed failure ownership.
pub const BoundedCaptureResult = union(enum) {
    completed: Result,
    stdout_limit_exceeded,
    stderr_limit_exceeded,
    failed: Failure,

    pub fn deinit(self: *BoundedCaptureResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed => |result| result.deinit(allocator),
            .failed => |*failure| failure.deinit(allocator),
            .stdout_limit_exceeded, .stderr_limit_exceeded => {},
        }
        self.* = .{ .failed = .empty_argv };
    }
};

const FailurePhase = enum {
    capture,
    wait,
    stdin,
};

fn primaryFailurePhase(capture_error: ?anyerror, wait_error: ?anyerror, stdin_error: ?anyerror) ?FailurePhase {
    if (capture_error != null) return .capture;
    if (wait_error != null) return .wait;
    if (stdin_error != null) return .stdin;
    return null;
}

fn failureWithoutResult(capture_error: ?anyerror, wait_error: ?anyerror, stdin_error: ?anyerror) Failure {
    return switch (primaryFailurePhase(capture_error, wait_error, stdin_error).?) {
        .capture => .{ .capture = capture_error.? },
        .wait => .{ .wait = wait_error.? },
        .stdin => unreachable,
    };
}

/// Run a child process with structured argv and captured stdout/stderr, without stdin.
pub fn runCaptured(allocator: std.mem.Allocator, io: std.Io, options: Options) Error!Result {
    var captured_options = options;
    captured_options.stdin = &.{};
    return runWithStdin(allocator, io, captured_options);
}

/// Bounded counterpart to `runCaptured` which keeps stdout and stderr limit
/// terminals distinct for domains whose public failure taxonomy depends on
/// the overflowing stream.
pub fn runCapturedBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) std.mem.Allocator.Error!BoundedCaptureResult {
    var captured_options = options;
    captured_options.stdin = &.{};
    return runWithStdinBounded(allocator, io, captured_options);
}

/// Run a child process with structured argv and captured stdout/stderr.
///
/// Git commands use this runner so process ownership,
/// stdin handling, output caps, and child cleanup stay in one place.
pub fn runWithStdin(allocator: std.mem.Allocator, io: std.Io, options: Options) Error!Result {
    const detailed = try runWithStdinDetailed(allocator, io, options);
    return resultFromDetailed(allocator, detailed);
}

/// Bounded counterpart to `runWithStdin`. The implementation shares the same
/// spawn, pump, capture, kill/reap, and allocation owner as the legacy API.
pub fn runWithStdinBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) std.mem.Allocator.Error!BoundedCaptureResult {
    const detailed = try runWithStdinDetailedInternal(allocator, io, options, .distinct);
    return switch (detailed) {
        .ok => |result| .{ .completed = result },
        .failed => |failure| switch (failure) {
            .capture => |err| if (err == error.StdoutLimitExceeded)
                .stdout_limit_exceeded
            else if (err == error.StderrLimitExceeded)
                .stderr_limit_exceeded
            else
                .{ .failed = failure },
            else => .{ .failed = failure },
        },
    };
}

fn resultFromDetailed(allocator: std.mem.Allocator, detailed: DetailedResult) Error!Result {
    return switch (detailed) {
        .ok => |result| result,
        .failed => |failure_value| {
            var failure = failure_value;
            defer failure.deinit(allocator);
            if (failure == .capture and
                (failure.capture == error.StdoutLimitExceeded or failure.capture == error.StderrLimitExceeded))
            {
                return error.StreamTooLong;
            }
            return failure.toError();
        },
    };
}

/// Same process runner as `runWithStdin`, but preserves the failure phase.
///
/// Consumers which need failure evidence use this to distinguish "could not
/// start command" from "command started, but runner IO/capture/wait failed".
pub fn runWithStdinDetailed(allocator: std.mem.Allocator, io: std.Io, options: Options) std.mem.Allocator.Error!DetailedResult {
    return runWithStdinDetailedInternal(allocator, io, options, .coalesced);
}

const LimitClassification = enum { coalesced, distinct };

fn runWithStdinDetailedInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    limit_classification: LimitClassification,
) std.mem.Allocator.Error!DetailedResult {
    if (options.argv.len == 0) return .{ .failed = .empty_argv };

    var child = std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return .{ .failed = .{ .spawn = err } };
    var child_waited = false;
    var stdin_future: ?std.Io.Future(?anyerror) = null;
    defer {
        if (!child_waited) child.kill(io);
        if (stdin_future) |*future| _ = future.cancel(io);
    }

    const stdin_file = child.stdin.?;
    child.stdin = null;
    var stdin_error: ?anyerror = null;
    if (options.stdin.len == 0) {
        stdin_file.close(io);
    } else {
        stdin_future = io.concurrent(pumpStdin, .{ stdin_file, io, options.stdin }) catch |err| {
            // Keep stdin open until the child is reaped so admission failure
            // cannot look like a normal EOF to the command.
            child.kill(io);
            child_waited = true;
            stdin_file.close(io);
            return .{ .failed = .{ .stdin_start = err } };
        };
    }

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    var capture_error: ?anyerror = null;
    while (multi_reader.fill(64, .none)) |_| {
        if (options.stdout_limit.toInt()) |limit| {
            if (stdout_reader.buffered().len > limit) {
                capture_error = if (limit_classification == .distinct)
                    error.StdoutLimitExceeded
                else
                    error.StreamTooLong;
                break;
            }
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (stderr_reader.buffered().len > limit) {
                capture_error = if (limit_classification == .distinct)
                    error.StderrLimitExceeded
                else
                    error.StreamTooLong;
                break;
            }
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| capture_error = e,
    }

    if (capture_error == null) {
        multi_reader.checkAnyError() catch |err| {
            capture_error = err;
        };
    }
    if (capture_error) |err| {
        return .{ .failed = failureWithoutResult(err, null, stdin_error) };
    }

    if (stdin_future) |*future| {
        stdin_error = future.await(io);
        stdin_future = null;
    }

    const term = child.wait(io) catch |err| {
        return .{ .failed = failureWithoutResult(null, err, stdin_error) };
    };
    child_waited = true;
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    const result: Result = .{ .term = term, .stdout = stdout, .stderr = stderr };
    if (stdin_error) |err| {
        std.debug.assert(primaryFailurePhase(null, null, err).? == .stdin);
        return .{ .failed = .{ .stdin = .{ .err = err, .result = result } } };
    }
    return .{ .ok = result };
}

fn pumpStdin(file: std.Io.File, io: std.Io, stdin: []const u8) ?anyerror {
    defer file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &write_buffer);
    writer.interface.writeAll(stdin) catch |err| return writer.err orelse err;
    writer.interface.flush() catch |err| return writer.err orelse err;
    return null;
}

const ControlTerminal = enum {
    canceled,
    timed_out,
};

const ControlledTestHooks = struct {
    terminate_grace: std.Io.Duration = .fromSeconds(1),
    wait_failure_after_reap: ?anyerror = null,
    group_signal_failure: ?anyerror = null,
    lifecycle_audit: ?*ControlledLifecycleAudit = null,
    ready_race: ?*ControlledReadyRace = null,
    synchronize_final_signal_after_child_exit: bool = false,
};

const ControlledLifecycleAudit = struct {
    signal_attempts: usize = 0,
    signal_attempts_after_reap: usize = 0,
    wait_calls: usize = 0,
    reaps: usize = 0,
    signal_attempts_after_child_exit: usize = 0,
    child_exit_observed: std.atomic.Value(bool) = .init(false),
};

const ControlledReadyRace = struct {
    canceled_generation: *std.atomic.Value(u64),
    generation: u64,
    child_observed: std.atomic.Value(bool) = .init(false),
    control_observed: std.atomic.Value(bool) = .init(false),
};

const WaitPhaseResult = union(enum) {
    completed: std.process.Child.Term,
    stopped: ControlTerminal,
    failed: ControlledFailure,
};

const ChildReadyResult = anyerror!void;
const ControlWatchResult = std.Io.Cancelable!ControlTerminal;
const WaitEvent = union(enum) {
    child_ready: ChildReadyResult,
    control: ControlWatchResult,
};

const DarwinWaitId = struct {
    extern "c" fn waitid(id_type: c_uint, id: u32, info: *std.c.siginfo_t, options: c_int) c_int;
};

const DarwinProcessInfo = if (builtin.os.tag == .macos) @cImport({
    @cInclude("sys/sysctl.h");
}) else struct {};

const ZeroizingAllocator = struct {
    child: std.mem.Allocator,

    fn allocator(self: *ZeroizingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ZeroizingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ZeroizingAllocator = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, memory);
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

fn supportsControlledProcessGroups() bool {
    return switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    };
}

fn pollControl(io: std.Io, control: ProcessControl) ?ControlTerminal {
    if (control.cancellation) |cancellation| {
        if (cancellation.requested()) return .canceled;
    }
    if (control.deadline) |deadline| {
        const now = std.Io.Clock.Timestamp.now(io, deadline.clock);
        if (deadline.compare(.lte, now)) return .timed_out;
    }
    return null;
}

fn captureTimeout(io: std.Io, control: ProcessControl) std.Io.Timeout {
    if (control.cancellation == null) {
        return if (control.deadline) |deadline| .{ .deadline = deadline } else .none;
    }

    const clock = if (control.deadline) |deadline| deadline.clock else std.Io.Clock.awake;
    const poll_deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(8),
        .clock = clock,
    });
    if (control.deadline) |deadline| {
        if (deadline.compare(.lte, poll_deadline)) return .{ .deadline = deadline };
    }
    return .{ .deadline = poll_deadline };
}

fn watchControl(io: std.Io, control: ProcessControl, hooks: ControlledTestHooks) ControlWatchResult {
    while (true) {
        if (pollControl(io, control)) |terminal| {
            if (hooks.ready_race) |race| {
                race.control_observed.store(true, .release);
                while (!race.child_observed.load(.acquire)) {
                    try io.sleep(.fromMilliseconds(1), .awake);
                }
                // Let the non-reaping child observer publish its event first.
                // This test-only barrier proves the real concurrent boundary
                // without depending on scheduler timing.
                try io.sleep(.fromMilliseconds(10), .awake);
            }
            return terminal;
        }
        try captureTimeout(io, control).sleep(io);
    }
}

fn childExitedWithoutReaping(pid: std.posix.pid_t) anyerror!bool {
    return switch (builtin.os.tag) {
        .linux => linux: {
            const linux_os = std.os.linux;
            var info: linux_os.siginfo_t = std.mem.zeroes(linux_os.siginfo_t);
            while (true) switch (linux_os.errno(linux_os.waitid(
                .PID,
                pid,
                &info,
                linux_os.W.EXITED | linux_os.W.NOWAIT | linux_os.W.NOHANG,
                null,
            ))) {
                .SUCCESS => break :linux info.fields.common.first.piduid.pid != 0,
                .INTR => continue,
                .CHILD => return error.ChildAlreadyReaped,
                else => |err| return std.posix.unexpectedErrno(err),
            };
        },
        .macos => darwin: {
            var info: std.c.siginfo_t = std.mem.zeroes(std.c.siginfo_t);
            while (true) switch (std.c.errno(DarwinWaitId.waitid(
                1, // P_PID
                @intCast(pid),
                &info,
                0x00000001 | // WNOHANG
                    0x00000004 | // WEXITED
                    0x00000020, // WNOWAIT
            ))) {
                .SUCCESS => break :darwin info.pid != 0,
                .INTR => continue,
                .CHILD => return error.ChildAlreadyReaped,
                else => |err| return std.posix.unexpectedErrno(err),
            };
        },
        else => unreachable,
    };
}

fn recordChildExitObserved(hooks: ControlledTestHooks) void {
    if (hooks.lifecycle_audit) |audit| audit.child_exit_observed.store(true, .release);
}

fn observeChildExit(
    io: std.Io,
    pid: std.posix.pid_t,
    hooks: ControlledTestHooks,
) ChildReadyResult {
    while (!try childExitedWithoutReaping(pid)) {
        try io.sleep(.fromMilliseconds(8), .awake);
    }
    if (hooks.lifecycle_audit) |audit| audit.child_exit_observed.store(true, .release);
    if (hooks.ready_race) |race| {
        race.canceled_generation.store(race.generation, .release);
        race.child_observed.store(true, .release);
        while (!race.control_observed.load(.acquire)) {
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }
}

fn childReadyResultFromEvents(events: []const WaitEvent) ?ChildReadyResult {
    for (events) |event| switch (event) {
        .child_ready => |result| return result,
        .control => {},
    };
    return null;
}

fn controlResultFromEvents(events: []const WaitEvent) ?ControlWatchResult {
    for (events) |event| switch (event) {
        .child_ready => {},
        .control => |result| return result,
    };
    return null;
}

fn recordSignalAttempt(child: *const std.process.Child, hooks: ControlledTestHooks) void {
    if (hooks.lifecycle_audit) |audit| {
        audit.signal_attempts += 1;
        if (child.id == null) audit.signal_attempts_after_reap += 1;
        if (audit.child_exit_observed.load(.acquire)) audit.signal_attempts_after_child_exit += 1;
    }
}

fn signalProcessGroup(
    child: *const std.process.Child,
    pid: std.posix.pid_t,
    signal: std.posix.SIG,
    hooks: ControlledTestHooks,
) ?anyerror {
    std.debug.assert(child.id != null and child.id.? == pid);
    recordSignalAttempt(child, hooks);
    const signal_error = hooks.group_signal_failure orelse failed: {
        std.posix.kill(-pid, signal) catch |err| break :failed err;
        return null;
    };
    if (signal_error == error.ProcessNotFound) return null;
    if (builtin.os.tag == .macos and signal_error == error.PermissionDenied and
        darwinProcessGroupExiting(pid, std.heap.page_allocator, &std.c.sysctl)) return null;
    return signal_error;
}

/// Darwin's group kill can return EPERM when every member is already exiting
/// or a zombie. A leader's waitid result alone cannot establish this: a live
/// descendant may remain, and P_WEXIT precedes waitid's completion observation.
/// Never use partial or failed queries to suppress a real permission failure.
fn darwinProcessGroupExiting(
    pid: std.posix.pid_t,
    allocator: std.mem.Allocator,
    query: *const @TypeOf(std.c.sysctl),
) bool {
    const c = DarwinProcessInfo;
    const mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PGRP, pid };
    const max_bytes = 4 * 1024 * 1024;
    for (0..3) |_| {
        var size: usize = 0;
        switch (std.c.errno(query(&mib, mib.len, null, &size, null, 0))) {
            .SUCCESS => {},
            .INTR, .NOMEM => continue,
            else => return false,
        }
        if (size > max_bytes or size % @sizeOf(c.struct_kinfo_proc) != 0) return false;
        // Even a zero size query needs a non-null data buffer for a fresh,
        // complete snapshot rather than another size-only observation.
        const members = allocator.alloc(c.struct_kinfo_proc, @max(1, size / @sizeOf(c.struct_kinfo_proc))) catch return false;
        defer allocator.free(members);
        size = std.mem.sliceAsBytes(members).len;
        switch (std.c.errno(query(&mib, mib.len, members.ptr, &size, null, 0))) {
            .SUCCESS => {},
            .INTR, .NOMEM => continue,
            else => return false,
        }
        if (size > std.mem.sliceAsBytes(members).len or size % @sizeOf(c.struct_kinfo_proc) != 0) return false;
        for (members[0 .. size / @sizeOf(c.struct_kinfo_proc)]) |member| {
            if (member.kp_proc.p_pid <= 0 or member.kp_eproc.e_pgid != pid) return false;
            if (member.kp_proc.p_stat != c.SZOMB and member.kp_proc.p_flag & c.P_WEXIT == 0) return false;
        }
        return true;
    }
    return false;
}

fn signalDirectChild(
    child: *const std.process.Child,
    pid: std.posix.pid_t,
    signal: std.posix.SIG,
    hooks: ControlledTestHooks,
) ?anyerror {
    recordSignalAttempt(child, hooks);
    std.posix.kill(pid, signal) catch |err| switch (err) {
        error.ProcessNotFound => return null,
        else => |signal_error| return signal_error,
    };
    return null;
}

fn beginGroupTermination(
    child: *const std.process.Child,
    pid: std.posix.pid_t,
    hooks: ControlledTestHooks,
) ?anyerror {
    return signalProcessGroup(child, pid, .TERM, hooks);
}

fn finishGroupTermination(
    child: *const std.process.Child,
    pid: std.posix.pid_t,
    hooks: ControlledTestHooks,
) ?anyerror {
    const group_error = signalProcessGroup(child, pid, .KILL, hooks);
    if (signalDirectChild(child, pid, .KILL, hooks)) |direct_error| {
        if (group_error == null) return direct_error;
    }
    return group_error;
}

fn reapChild(
    child: *std.process.Child,
    io: std.Io,
    hooks: ControlledTestHooks,
) anyerror!std.process.Child.Term {
    if (hooks.lifecycle_audit) |audit| audit.wait_calls += 1;
    const term = try child.wait(io);
    if (hooks.lifecycle_audit) |audit| {
        if (child.id == null) audit.reaps += 1;
    }
    if (hooks.wait_failure_after_reap) |err| return err;
    return term;
}

fn synchronizeFinalSignal(io: std.Io, hooks: ControlledTestHooks) void {
    if (!hooks.synchronize_final_signal_after_child_exit) return;
    const audit = hooks.lifecycle_audit orelse return;
    for (0..1000) |_| {
        if (audit.child_exit_observed.load(.acquire)) return;
        io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
    }
}

fn terminateGroupAndReap(
    child: *std.process.Child,
    io: std.Io,
    pid: std.posix.pid_t,
    hooks: ControlledTestHooks,
) ?ControlledFailure {
    var terminate_error = beginGroupTermination(child, pid, hooks);
    io.sleep(hooks.terminate_grace, .awake) catch unreachable;
    synchronizeFinalSignal(io, hooks);
    if (finishGroupTermination(child, pid, hooks)) |err| {
        if (terminate_error == null) terminate_error = err;
    }

    _ = reapChild(child, io, hooks) catch |err| return .{ .wait = err };
    if (terminate_error) |err| return .{ .terminate = err };
    return null;
}

fn waitForControlledChild(
    child: *std.process.Child,
    io: std.Io,
    pid: std.posix.pid_t,
    control: ProcessControl,
    hooks: ControlledTestHooks,
) WaitPhaseResult {
    if (control.deadline == null and control.cancellation == null) {
        const term = reapChild(child, io, hooks) catch |err| return .{ .failed = .{ .wait = err } };
        return .{ .completed = term };
    }

    var event_storage: [2]WaitEvent = undefined;
    var select: std.Io.Select(WaitEvent) = .init(io, &event_storage);
    select.concurrent(.control, watchControl, .{ io, control, hooks }) catch |err| {
        if (terminateGroupAndReap(child, io, pid, hooks)) |cleanup_failure| {
            return .{ .failed = cleanup_failure };
        }
        return .{ .failed = .{ .control_start = err } };
    };
    select.concurrent(.child_ready, observeChildExit, .{ io, pid, hooks }) catch |err| {
        select.cancelDiscard();
        if (terminateGroupAndReap(child, io, pid, hooks)) |cleanup_failure| {
            return .{ .failed = cleanup_failure };
        }
        return .{ .failed = .{ .control_start = err } };
    };
    defer select.cancelDiscard();

    var ready: [2]WaitEvent = undefined;
    const ready_len = select.awaitMany(&ready, 1) catch unreachable;

    // A non-reaping direct-child observation already present in the same
    // ready batch wins the completion/control race. Cancel the watcher before
    // the single destructive wait so no signal can follow identity release.
    if (childReadyResultFromEvents(ready[0..ready_len])) |child_ready_result| {
        _ = child_ready_result catch |err| {
            if (terminateGroupAndReap(child, io, pid, hooks)) |cleanup_failure| {
                return .{ .failed = cleanup_failure };
            }
            return .{ .failed = .{ .wait = err } };
        };
        select.cancelDiscard();
        const term = reapChild(child, io, hooks) catch |err| return .{ .failed = .{ .wait = err } };
        return .{ .completed = term };
    }

    const control_result = controlResultFromEvents(ready[0..ready_len]).?;
    const terminal = control_result catch unreachable;
    var terminate_error = beginGroupTermination(child, pid, hooks);
    io.sleep(hooks.terminate_grace, .awake) catch unreachable;
    synchronizeFinalSignal(io, hooks);
    // The observer uses WNOWAIT, so the direct child remains the original
    // PID/PGID anchor through the final group and direct-child signals even
    // when TERM made it a zombie during the grace period.
    if (finishGroupTermination(child, pid, hooks)) |err| {
        if (terminate_error == null) terminate_error = err;
    }
    select.cancelDiscard();
    _ = reapChild(child, io, hooks) catch |err| return .{ .failed = .{ .wait = err } };
    if (terminate_error) |err| return .{ .failed = .{ .terminate = err } };
    return .{ .stopped = terminal };
}

fn takeSensitiveBytes(multi_reader: *std.Io.File.MultiReader, index: usize, allocator: std.mem.Allocator) SensitiveBytes {
    const reader = multi_reader.reader(index);
    std.debug.assert(reader.seek == 0);
    const allocation = reader.buffer;
    const result: SensitiveBytes = .{
        .allocator = allocator,
        .storage = if (allocation.len == 0) null else allocation.ptr,
        .len = reader.end,
        .capacity = allocation.len,
    };
    reader.buffer = &.{};
    reader.seek = 0;
    reader.end = 0;
    return result;
}

fn finishControlledCapture(
    allocator: std.mem.Allocator,
    multi_reader: *std.Io.File.MultiReader,
    capture_mode: CaptureMode,
    term: std.process.Child.Term,
) ControlledResult {
    return switch (capture_mode) {
        .ordinary => ordinary: {
            const stdout = multi_reader.toOwnedSlice(0) catch |err| {
                break :ordinary .{ .failed = .{ .capture = err } };
            };
            const stderr = multi_reader.toOwnedSlice(1) catch |err| {
                allocator.free(stdout);
                break :ordinary .{ .failed = .{ .capture = err } };
            };
            break :ordinary .{ .completed = .{ .ordinary = .{
                .term = term,
                .stdout = stdout,
                .stderr = stderr,
            } } };
        },
        .sensitive => .{ .completed = .{ .sensitive = .{
            .term = term,
            .stdout = takeSensitiveBytes(multi_reader, 0, allocator),
            .stderr = takeSensitiveBytes(multi_reader, 1, allocator),
        } } },
    };
}

fn controlledPollTimeout(io: std.Io, control: ProcessControl) std.Io.Timeout {
    const poll_deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(8),
        .clock = if (control.deadline) |deadline| deadline.clock else std.Io.Clock.awake,
    });
    if (control.deadline) |deadline| {
        if (deadline.compare(.lte, poll_deadline)) return .{ .deadline = deadline };
    }
    return .{ .deadline = poll_deadline };
}

fn controlledLimitError(
    multi_reader: *std.Io.File.MultiReader,
    options: Options,
) ?anyerror {
    if (options.stdout_limit.toInt()) |limit| {
        if (multi_reader.reader(0).buffered().len > limit) return error.StdoutLimitExceeded;
    }
    if (options.stderr_limit.toInt()) |limit| {
        if (multi_reader.reader(1).buffered().len > limit) return error.StderrLimitExceeded;
    }
    return null;
}

fn drainControlledPipes(
    multi_reader: *std.Io.File.MultiReader,
    io: std.Io,
    options: Options,
) ?anyerror {
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromSeconds(2),
        .clock = .awake,
    });
    while (true) {
        multi_reader.fill(64, .{ .deadline = deadline }) catch |err| switch (err) {
            error.EndOfStream => return controlledLimitError(multi_reader, options),
            else => return err,
        };
        if (controlledLimitError(multi_reader, options)) |err| return err;
    }
}

/// Run a child in one dedicated process group while concurrently pumping a
/// bounded stdin document and capturing both output streams. Unlike the
/// existing controlled capture entry below, every terminal drains and empties
/// the process group before the direct leader is reaped.
pub fn runWithStdinControlled(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    capture_mode: CaptureMode,
    control: ProcessControl,
) ControlledResult {
    return runWithStdinControlledInternal(allocator, io, options, capture_mode, control, .{});
}

fn runWithStdinControlledInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    capture_mode: CaptureMode,
    control: ProcessControl,
    hooks: ControlledTestHooks,
) ControlledResult {
    if (options.argv.len == 0) return .{ .failed = .empty_argv };
    if (comptime !supportsControlledProcessGroups()) {
        return .{ .failed = .unsupported_process_control };
    }

    const previous_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous_cancel_protection);
    if (pollControl(io, control)) |terminal| return switch (terminal) {
        .canceled => .{ .canceled = .not_started },
        .timed_out => .{ .timed_out = .not_started },
    };

    var child = std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| return .{ .failed = .{ .spawn = err } };
    const pid = child.id.?;
    var child_owned = true;
    defer if (child_owned) child.kill(io);

    var zeroizing_allocator: ZeroizingAllocator = .{ .child = allocator };
    const capture_allocator = switch (capture_mode) {
        .ordinary => allocator,
        .sensitive => zeroizing_allocator.allocator(),
    };
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(capture_allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdin_file = child.stdin.?;
    child.stdin = null;
    var stdin_future: ?std.Io.Future(?anyerror) = null;
    var stdin_start_error: ?std.Io.ConcurrentError = null;
    if (options.stdin.len == 0) {
        stdin_file.close(io);
    } else {
        if (io.concurrent(pumpStdin, .{ stdin_file, io, options.stdin })) |future| {
            stdin_future = future;
        } else |err| {
            stdin_start_error = err;
            stdin_file.close(io);
        }
    }
    defer {
        if (stdin_future) |*future| _ = future.cancel(io);
    }

    var leader_ready = false;
    var observer_error: ?anyerror = null;
    var capture_error: ?anyerror = null;
    var stopped: ?ControlTerminal = null;
    while (stdin_start_error == null) {
        const exited_before = childExitedWithoutReaping(pid) catch |err| {
            observer_error = err;
            break;
        };
        if (exited_before) {
            leader_ready = true;
            recordChildExitObserved(hooks);
            break;
        }

        multi_reader.fill(64, controlledPollTimeout(io, control)) catch |err| switch (err) {
            error.Timeout, error.EndOfStream => {},
            else => {
                capture_error = err;
                break;
            },
        };
        multi_reader.checkAnyError() catch |err| {
            capture_error = err;
            break;
        };
        if (controlledLimitError(&multi_reader, options)) |err| {
            capture_error = err;
            break;
        }

        // Check the non-reaping child state on both sides of control polling;
        // a leader already ready in this observation batch wins the race.
        const exited_after = childExitedWithoutReaping(pid) catch |err| {
            observer_error = err;
            break;
        };
        if (exited_after) {
            leader_ready = true;
            recordChildExitObserved(hooks);
            break;
        }
        if (pollControl(io, control)) |terminal| {
            const exited_with_control = childExitedWithoutReaping(pid) catch |err| {
                observer_error = err;
                break;
            };
            if (exited_with_control) {
                leader_ready = true;
                recordChildExitObserved(hooks);
            } else stopped = terminal;
            break;
        }
    }

    var stdin_error: ?anyerror = null;
    if (stdin_future) |*future| {
        stdin_error = future.cancel(io);
        stdin_future = null;
        if (stdin_error) |err| {
            if (err == error.Canceled) stdin_error = null;
        }
    }

    var terminate_error = beginGroupTermination(&child, pid, hooks);
    io.sleep(hooks.terminate_grace, .awake) catch unreachable;
    synchronizeFinalSignal(io, hooks);
    if (finishGroupTermination(&child, pid, hooks)) |err| {
        if (terminate_error == null) terminate_error = err;
    }
    const drain_error = drainControlledPipes(&multi_reader, io, options);
    const term = reapChild(&child, io, hooks) catch |err| {
        child_owned = false;
        return .{ .failed = .{ .wait = err } };
    };
    child_owned = false;

    if (terminate_error) |err| return .{ .failed = .{ .terminate = err } };
    if (observer_error) |err| return .{ .failed = .{ .wait = err } };
    if (stopped) |terminal| return switch (terminal) {
        .canceled => .{ .canceled = .started },
        .timed_out => .{ .timed_out = .started },
    };
    if (capture_error) |err| return .{ .failed = .{ .capture = err } };
    if (drain_error) |err| return .{ .failed = .{ .capture = err } };
    if (stdin_start_error) |err| return .{ .failed = .{ .stdin_start = err } };
    if (stdin_error) |err| return .{ .failed = .{ .stdin = err } };
    if (!leader_ready) return .{ .failed = .{ .wait = error.ChildNotObserved } };
    return finishControlledCapture(allocator, &multi_reader, capture_mode, term);
}

/// Existing capture-only controlled entry. Callers that need bounded stdin use
/// the separate controlled-stdin entry above.
pub fn runCapturedControlled(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    capture_mode: CaptureMode,
    control: ProcessControl,
) ControlledResult {
    return runCapturedControlledInternal(allocator, io, options, capture_mode, control, .{});
}

fn runCapturedControlledInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    capture_mode: CaptureMode,
    control: ProcessControl,
    hooks: ControlledTestHooks,
) ControlledResult {
    if (options.argv.len == 0) return .{ .failed = .empty_argv };
    if (comptime !supportsControlledProcessGroups()) {
        return .{ .failed = .unsupported_process_control };
    }

    const previous_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous_cancel_protection);

    if (pollControl(io, control)) |terminal| return switch (terminal) {
        .canceled => .{ .canceled = .not_started },
        .timed_out => .{ .timed_out = .not_started },
    };

    var child = std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| return .{ .failed = .{ .spawn = err } };
    const pid = child.id.?;
    var child_owned = true;
    defer if (child_owned) child.kill(io);

    child.stdin.?.close(io);
    child.stdin = null;

    var zeroizing_allocator: ZeroizingAllocator = .{ .child = allocator };
    const capture_allocator = switch (capture_mode) {
        .ordinary => allocator,
        .sensitive => zeroizing_allocator.allocator(),
    };

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(capture_allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    var multi_reader_active = true;
    defer if (multi_reader_active) multi_reader.deinit();

    var capture_error: ?anyerror = null;
    var stopped: ?ControlTerminal = null;
    capture: while (true) {
        multi_reader.checkAnyError() catch |err| {
            capture_error = err;
            break :capture;
        };
        multi_reader.fill(64, captureTimeout(io, control)) catch |err| switch (err) {
            error.Timeout => {
                if (pollControl(io, control)) |terminal| {
                    stopped = terminal;
                    break :capture;
                }
                continue :capture;
            },
            error.EndOfStream => break :capture,
            else => |fill_error| {
                capture_error = fill_error;
                break :capture;
            },
        };
        multi_reader.checkAnyError() catch |err| {
            capture_error = err;
            break :capture;
        };

        const stdout_reader = multi_reader.reader(0);
        const stderr_reader = multi_reader.reader(1);
        if (options.stdout_limit.toInt()) |limit| {
            if (stdout_reader.buffered().len > limit) {
                capture_error = error.StreamTooLong;
                break :capture;
            }
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (stderr_reader.buffered().len > limit) {
                capture_error = error.StreamTooLong;
                break :capture;
            }
        }
        if (pollControl(io, control)) |terminal| {
            stopped = terminal;
            break :capture;
        }
    }

    if (capture_error == null and stopped == null) {
        multi_reader.checkAnyError() catch |err| {
            capture_error = err;
        };
    }

    if (capture_error != null or stopped != null) {
        multi_reader.deinit();
        multi_reader_active = false;
        const cleanup_failure = terminateGroupAndReap(&child, io, pid, hooks);
        child_owned = false;
        if (cleanup_failure) |failure| return .{ .failed = failure };
        if (capture_error) |err| return .{ .failed = .{ .capture = err } };
        return switch (stopped.?) {
            .canceled => .{ .canceled = .started },
            .timed_out => .{ .timed_out = .started },
        };
    }

    const wait_result = waitForControlledChild(&child, io, pid, control, hooks);
    child_owned = false;
    return switch (wait_result) {
        .completed => |term| finishControlledCapture(allocator, &multi_reader, capture_mode, term),
        .stopped => |terminal| switch (terminal) {
            .canceled => .{ .canceled = .started },
            .timed_out => .{ .timed_out = .started },
        },
        .failed => |failure| .{ .failed = failure },
    };
}

const TestWatchResult = union(enum) {
    runner: std.mem.Allocator.Error!DetailedResult,
    timeout: std.Io.Cancelable!void,
};

fn testWatchdogSleep(io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(5), .awake);
}

fn deinitTestWatchResult(allocator: std.mem.Allocator, result: TestWatchResult) void {
    switch (result) {
        .runner => |runner_result| {
            var detailed = runner_result catch return;
            detailed.deinit(allocator);
        },
        .timeout => {},
    }
}

fn drainTestWatchSelect(allocator: std.mem.Allocator, select: *std.Io.Select(TestWatchResult)) void {
    while (select.cancel()) |result| deinitTestWatchResult(allocator, result);
}

fn runDetailedWithTestWatchdog(allocator: std.mem.Allocator, io: std.Io, options: Options) !DetailedResult {
    var result_buffer: [2]TestWatchResult = undefined;
    var select: std.Io.Select(TestWatchResult) = .init(io, &result_buffer);
    defer drainTestWatchSelect(allocator, &select);

    try select.concurrent(.runner, runWithStdinDetailed, .{ allocator, io, options });
    try select.concurrent(.timeout, testWatchdogSleep, .{io});

    return switch (try select.await()) {
        .runner => |runner_result| try runner_result,
        .timeout => |timeout_result| {
            try timeout_result;
            return error.TestTimedOut;
        },
    };
}

test "concurrent stdin preserves diagnostics after early child exit" {
    const stdin = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(stdin);
    @memset(stdin, 'i');

    const argv = [_][]const u8{ "sh", "-c", "exec 0<&-; printf retained-diagnostic >&2; exit 7" };
    var detailed = try runDetailedWithTestWatchdog(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = stdin,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(1024),
    });
    defer detailed.deinit(std.testing.allocator);

    switch (detailed) {
        .failed => |failure| switch (failure) {
            .stdin => |stdin_failure| {
                try std.testing.expectEqualStrings("", stdin_failure.result.stdout);
                try std.testing.expectEqualStrings("retained-diagnostic", stdin_failure.result.stderr);
                try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, stdin_failure.result.term);
            },
            else => return error.ExpectedStdinFailure,
        },
        .ok => return error.ExpectedStdinFailure,
    }
}

test "concurrent stdin drains large bidirectional IO without deadlock" {
    const stdin = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(stdin);
    @memset(stdin, 'i');

    const output_bytes = 96 * 1024;
    const argv = [_][]const u8{
        "sh",
        "-c",
        "yes stdout | head -c 98304; yes stderr | head -c 98304 >&2; cat",
    };
    var detailed = try runDetailedWithTestWatchdog(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = stdin,
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
    });
    defer detailed.deinit(std.testing.allocator);

    const result = switch (detailed) {
        .ok => |result| result,
        .failed => return error.ExpectedSuccessfulBidirectionalRun,
    };
    try std.testing.expectEqual(output_bytes + stdin.len, result.stdout.len);
    try std.testing.expectEqual(output_bytes, result.stderr.len);
    try std.testing.expectEqualStrings(stdin, result.stdout[result.stdout.len - stdin.len ..]);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "concurrent stdin capture failure outranks simultaneous writer failure" {
    const stdin = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(stdin);
    @memset(stdin, 'i');

    const argv = [_][]const u8{
        "sh",
        "-c",
        "exec 0<&-; yes overflow | head -c 131072; printf ignored-diagnostic >&2; exit 9",
    };
    var detailed = try runDetailedWithTestWatchdog(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = stdin,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer detailed.deinit(std.testing.allocator);

    switch (detailed) {
        .failed => |failure| switch (failure) {
            .capture => |err| try std.testing.expectEqual(error.StreamTooLong, err),
            else => return error.ExpectedCaptureFailure,
        },
        .ok => return error.ExpectedCaptureFailure,
    }
}

test "concurrent stdin arbitration orders capture wait and writer failures" {
    try std.testing.expectEqual(
        FailurePhase.capture,
        primaryFailurePhase(error.StreamTooLong, error.AccessDenied, error.WriteFailed).?,
    );
    try std.testing.expectEqual(
        FailurePhase.wait,
        primaryFailurePhase(null, error.AccessDenied, error.WriteFailed).?,
    );
    try std.testing.expectEqual(
        FailurePhase.capture,
        primaryFailurePhase(error.StreamTooLong, null, error.WriteFailed).?,
    );
    try std.testing.expectEqual(
        FailurePhase.stdin,
        primaryFailurePhase(null, null, error.WriteFailed).?,
    );
}

test "stdin admission runner kills child when concurrency start is unavailable" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "IFS= read -r _ || :; printf child-ran > child-ran",
    };
    var detailed = try runWithStdinDetailed(std.testing.allocator, io, .{
        .argv = &argv,
        .cwd = .{ .dir = tmp.dir },
        .stdin = "payload",
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    });
    defer detailed.deinit(std.testing.allocator);

    switch (detailed) {
        .failed => |failure| switch (failure) {
            .stdin_start => |err| try std.testing.expectEqual(error.ConcurrencyUnavailable, err),
            else => return error.ExpectedStdinStartFailure,
        },
        .ok => return error.ExpectedStdinStartFailure,
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "child-ran", .{}));
}

test "stdin admission compatibility wrapper propagates concurrency unavailable" {
    try std.testing.expectError(error.ConcurrencyUnavailable, resultFromDetailed(std.testing.allocator, .{
        .failed = .{ .stdin_start = error.ConcurrencyUnavailable },
    }));
}

test "concurrent stdin compatibility wrapper releases failure evidence" {
    const stdout = try std.testing.allocator.dupe(u8, "out");
    const stderr = std.testing.allocator.dupe(u8, "diagnostic") catch |err| {
        std.testing.allocator.free(stdout);
        return err;
    };

    try std.testing.expectError(error.WriteFailed, resultFromDetailed(std.testing.allocator, .{
        .failed = .{ .stdin = .{
            .err = error.WriteFailed,
            .result = .{
                .term = .{ .exited = 7 },
                .stdout = stdout,
                .stderr = stderr,
            },
        } },
    }));
}

test "runCaptured captures stdout and stderr" {
    const argv = [_][]const u8{ "sh", "-c", "printf out; printf err >&2" };
    const result = try runCaptured(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("out", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "runCaptured forwards explicit environment map" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GITFRAME_RUNNER_SENTINEL", "explicit");

    const argv = [_][]const u8{ "sh", "-c", "printf %s \"$GITFRAME_RUNNER_SENTINEL\"" };
    const result = try runCaptured(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .environ_map = &env,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("explicit", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "runCaptured enforces output caps" {
    const argv = [_][]const u8{ "sh", "-c", "printf abcdef" };
    try std.testing.expectError(error.StreamTooLong, runCaptured(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdout_limit = .limited(3),
        .stderr_limit = .limited(64),
    }));
}

test "bounded capture distinguishes stdout and stderr overflow while legacy mapping stays stable" {
    const stdout_argv = [_][]const u8{ "sh", "-c", "printf abcdef" };
    var stdout_result = try runCapturedBounded(std.testing.allocator, std.testing.io, .{
        .argv = &stdout_argv,
        .stdout_limit = .limited(3),
        .stderr_limit = .limited(64),
    });
    defer stdout_result.deinit(std.testing.allocator);
    try std.testing.expect(stdout_result == .stdout_limit_exceeded);

    const stderr_argv = [_][]const u8{ "sh", "-c", "printf abcdef >&2" };
    var stderr_result = try runCapturedBounded(std.testing.allocator, std.testing.io, .{
        .argv = &stderr_argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(3),
    });
    defer stderr_result.deinit(std.testing.allocator);
    try std.testing.expect(stderr_result == .stderr_limit_exceeded);

    try std.testing.expectError(error.StreamTooLong, runCaptured(std.testing.allocator, std.testing.io, .{
        .argv = &stderr_argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(3),
    }));
}

test "bounded stdout and stderr overflow kill and reap their direct child" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const stdout_command = try std.fmt.allocPrint(
        std.testing.allocator,
        "printf %d $$ > '{s}/stdout.pid'; printf abcdef; exec sleep 60",
        .{root},
    );
    defer std.testing.allocator.free(stdout_command);
    const stdout_argv = [_][]const u8{ "sh", "-c", stdout_command };
    var stdout_result = try runCapturedBounded(std.testing.allocator, std.testing.io, .{
        .argv = &stdout_argv,
        .stdout_limit = .limited(3),
        .stderr_limit = .limited(64),
    });
    defer stdout_result.deinit(std.testing.allocator);
    try std.testing.expect(stdout_result == .stdout_limit_exceeded);
    try expectProcessGone(std.testing.io, try readTestPid(tmp.dir, std.testing.io, "stdout.pid"));

    const stderr_command = try std.fmt.allocPrint(
        std.testing.allocator,
        "printf %d $$ > '{s}/stderr.pid'; printf abcdef >&2; exec sleep 60",
        .{root},
    );
    defer std.testing.allocator.free(stderr_command);
    const stderr_argv = [_][]const u8{ "sh", "-c", stderr_command };
    var stderr_result = try runCapturedBounded(std.testing.allocator, std.testing.io, .{
        .argv = &stderr_argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(3),
    });
    defer stderr_result.deinit(std.testing.allocator);
    try std.testing.expect(stderr_result == .stderr_limit_exceeded);
    try expectProcessGone(std.testing.io, try readTestPid(tmp.dir, std.testing.io, "stderr.pid"));
}

test "runCaptured rejects empty argv" {
    try std.testing.expectError(error.EmptyArgv, runCaptured(std.testing.allocator, std.testing.io, .{
        .argv = &.{},
    }));
}

test "runWithStdin captures stdout and stderr" {
    const argv = [_][]const u8{ "sh", "-c", "printf out; printf err >&2" };
    const result = try runWithStdin(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = &.{},
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("out", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "runWithStdin writes stdin" {
    const argv = [_][]const u8{ "sh", "-c", "cat" };
    const result = try runWithStdin(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = "from stdin",
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("from stdin", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "runWithStdin enforces output caps" {
    const argv = [_][]const u8{ "sh", "-c", "printf abcdef" };
    try std.testing.expectError(error.StreamTooLong, runWithStdin(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdin = &.{},
        .stdout_limit = .limited(3),
        .stderr_limit = .limited(64),
    }));
}

test "runWithStdin rejects empty argv" {
    try std.testing.expectError(error.EmptyArgv, runWithStdin(std.testing.allocator, std.testing.io, .{
        .argv = &.{},
    }));
}

const ZeroAuditAllocator = struct {
    child: std.mem.Allocator,
    free_count: usize = 0,
    observed_nonzero_free: bool = false,

    fn allocator(self: *ZeroAuditAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ZeroAuditAllocator = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ZeroAuditAllocator = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ZeroAuditAllocator = @ptrCast(@alignCast(context));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ZeroAuditAllocator = @ptrCast(@alignCast(context));
        self.free_count += 1;
        for (memory) |byte| {
            if (byte != 0) {
                self.observed_nonzero_free = true;
            }
        }
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

fn requireControlledProcessTest() !void {
    if (!supportsControlledProcessGroups()) return error.SkipZigTest;
}

fn cancellationAfter(
    io: std.Io,
    canceled_generation: *std.atomic.Value(u64),
    generation: u64,
) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(40), .awake);
    canceled_generation.store(generation, .release);
}

fn readTestPid(dir: std.Io.Dir, io: std.Io, name: []const u8) !std.posix.pid_t {
    const bytes = try dir.readFileAlloc(io, name, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    return try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, bytes, " \r\n\t"), 10);
}

fn processExists(pid: std.posix.pid_t) !bool {
    const signal_zero: std.posix.SIG = @enumFromInt(0);
    std.posix.kill(pid, signal_zero) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => |unexpected| return unexpected,
    };
    return true;
}

fn expectProcessGone(io: std.Io, pid: std.posix.pid_t) !void {
    for (0..100) |_| {
        if (!try processExists(pid)) return;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.ProcessStillExists;
}

test "process group controlled ordinary capture preserves existing result ownership" {
    try requireControlledProcessTest();

    const argv = [_][]const u8{ "sh", "-c", "printf out; printf err >&2" };
    var controlled = runCapturedControlled(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    }, .ordinary, .{});
    defer controlled.deinit(std.testing.allocator);

    const result = switch (controlled) {
        .completed => |captured| switch (captured) {
            .ordinary => |result| result,
            .sensitive => return error.ExpectedOrdinaryCapture,
        },
        else => return error.ExpectedControlledCompletion,
    };
    try std.testing.expectEqualStrings("out", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "process cancel is generation scoped before and during a controlled run" {
    try requireControlledProcessTest();

    var canceled_generation: std.atomic.Value(u64) = .init(7);
    const quick_argv = [_][]const u8{ "sh", "-c", "printf completed" };
    var mismatched = runCapturedControlled(std.testing.allocator, std.testing.io, .{
        .argv = &quick_argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    }, .ordinary, .{ .cancellation = .{
        .canceled_generation = &canceled_generation,
        .generation = 8,
    } });
    defer mismatched.deinit(std.testing.allocator);
    switch (mismatched) {
        .completed => |captured| switch (captured) {
            .ordinary => |result| try std.testing.expectEqualStrings("completed", result.stdout),
            .sensitive => return error.ExpectedOrdinaryCapture,
        },
        else => return error.GenerationMismatchCanceledRun,
    }

    const should_not_spawn_argv = [_][]const u8{"/definitely/not/a/gitframe-command"};
    var canceled_before_spawn = runCapturedControlled(std.testing.allocator, std.testing.io, .{
        .argv = &should_not_spawn_argv,
    }, .ordinary, .{ .cancellation = .{
        .canceled_generation = &canceled_generation,
        .generation = 7,
    } });
    defer canceled_before_spawn.deinit(std.testing.allocator);
    try std.testing.expect(canceled_before_spawn == .canceled);
    try std.testing.expectEqual(SpawnPhase.not_started, canceled_before_spawn.canceled);

    canceled_generation.store(0, .release);
    var cancel_future = try std.testing.io.concurrent(cancellationAfter, .{
        std.testing.io,
        &canceled_generation,
        9,
    });
    defer _ = cancel_future.cancel(std.testing.io) catch {};

    const hanging_argv = [_][]const u8{ "sh", "-c", "trap '' TERM; while :; do sleep 1; done" };
    var canceled = runCapturedControlledInternal(std.testing.allocator, std.testing.io, .{
        .argv = &hanging_argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    }, .ordinary, .{ .cancellation = .{
        .canceled_generation = &canceled_generation,
        .generation = 9,
    } }, .{ .terminate_grace = .fromMilliseconds(20) });
    defer canceled.deinit(std.testing.allocator);
    try cancel_future.await(std.testing.io);
    try std.testing.expect(canceled == .canceled);
    try std.testing.expectEqual(SpawnPhase.started, canceled.canceled);
}

test "process timeout uses an absolute deadline before spawn and while running" {
    try requireControlledProcessTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const marker_argv = [_][]const u8{ "sh", "-c", "printf started > marker" };
    const expired_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = .fromMilliseconds(-1),
        .clock = .awake,
    });
    var expired = runCapturedControlled(std.testing.allocator, std.testing.io, .{
        .argv = &marker_argv,
        .cwd = .{ .dir = tmp.dir },
    }, .ordinary, .{ .deadline = expired_deadline });
    defer expired.deinit(std.testing.allocator);
    try std.testing.expect(expired == .timed_out);
    try std.testing.expectEqual(SpawnPhase.not_started, expired.timed_out);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "marker", .{}));

    const hanging_argv = [_][]const u8{ "sh", "-c", "trap '' TERM; while :; do sleep 1; done" };
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = .fromMilliseconds(50),
        .clock = .awake,
    });
    var timed_out = runCapturedControlledInternal(std.testing.allocator, std.testing.io, .{
        .argv = &hanging_argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    }, .ordinary, .{ .deadline = deadline }, .{ .terminate_grace = .fromMilliseconds(20) });
    defer timed_out.deinit(std.testing.allocator);
    try std.testing.expect(timed_out == .timed_out);
    try std.testing.expectEqual(SpawnPhase.started, timed_out.timed_out);
}

test "process cancel completion race prefers a ready child result" {
    try requireControlledProcessTest();

    var canceled_generation: std.atomic.Value(u64) = .init(0);
    var race: ControlledReadyRace = .{
        .canceled_generation = &canceled_generation,
        .generation = 17,
    };
    var audit: ControlledLifecycleAudit = .{};
    const argv = [_][]const u8{ "sh", "-c", "exit 0" };
    var result = runCapturedControlledInternal(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    }, .ordinary, .{ .cancellation = .{
        .canceled_generation = &canceled_generation,
        .generation = 17,
    } }, .{
        .lifecycle_audit = &audit,
        .ready_race = &race,
    });
    defer result.deinit(std.testing.allocator);

    const term = switch (result) {
        .completed => |captured| switch (captured) {
            .ordinary => |ordinary| ordinary.term,
            .sensitive => return error.ExpectedOrdinaryCapture,
        },
        else => return error.ExpectedControlledCompletion,
    };
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    try std.testing.expect(race.child_observed.load(.acquire));
    try std.testing.expect(race.control_observed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), audit.signal_attempts);
    try std.testing.expectEqual(@as(usize, 0), audit.signal_attempts_after_reap);
    try std.testing.expectEqual(@as(usize, 1), audit.wait_calls);
    try std.testing.expectEqual(@as(usize, 1), audit.reaps);
}

test "process group macOS snapshots require complete terminal membership" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const c = DarwinProcessInfo;
    const Fake = struct {
        const Mode = enum { normal, size_failure, data_failure, short_size, short_data, oversized_size, oversized_data, interrupted, growing, grow_once };
        var mode: Mode = .normal;
        var members: [2]c.struct_kinfo_proc = undefined;
        var count: usize = 2;
        var calls: usize = 0;

        fn query(mib: [*]const c_int, len: c_uint, buffer: ?*anyopaque, size: ?*usize, new: ?*anyopaque, new_len: usize) callconv(.c) c_int {
            std.debug.assert(len == 4 and mib[2] == c.KERN_PROC_PGRP and mib[3] == 541);
            std.debug.assert(new == null and new_len == 0);
            calls += 1;
            const failure: std.posix.E = switch (mode) {
                .size_failure => if (buffer == null) .PERM else .SUCCESS,
                .data_failure => if (buffer != null) .PERM else .SUCCESS,
                .interrupted => .INTR,
                .growing => if (buffer != null) .NOMEM else .SUCCESS,
                .grow_once => if (calls == 2) .NOMEM else .SUCCESS,
                else => .SUCCESS,
            };
            if (failure != .SUCCESS) {
                std.c._errno().* = @intFromEnum(failure);
                return -1;
            }
            if (buffer == null) {
                size.?.* = switch (mode) {
                    .short_size => 1,
                    .oversized_size => 4 * 1024 * 1024 + @sizeOf(c.struct_kinfo_proc),
                    else => count * @sizeOf(c.struct_kinfo_proc),
                };
                return 0;
            }
            if (mode == .short_data or mode == .oversized_data) {
                size.?.* = if (mode == .short_data) 1 else size.?.* + @sizeOf(c.struct_kinfo_proc);
                return 0;
            }
            const destination: [*]c.struct_kinfo_proc = @ptrCast(@alignCast(buffer.?));
            std.debug.assert(size.?.* >= count * @sizeOf(c.struct_kinfo_proc));
            @memcpy(destination[0..count], members[0..count]);
            size.?.* = count * @sizeOf(c.struct_kinfo_proc);
            return 0;
        }
    };
    Fake.members = @splat(std.mem.zeroes(c.struct_kinfo_proc));
    for (&Fake.members, 0..) |*member, i| {
        member.kp_proc.p_pid = @intCast(541 + i);
        member.kp_eproc.e_pgid = 541;
        member.kp_proc.p_stat = c.SZOMB;
    }
    // P_WEXIT is already terminal even before waitid can observe completion.
    Fake.members[1].kp_proc.p_stat = c.SRUN;
    Fake.members[1].kp_proc.p_flag = c.P_WEXIT;
    try std.testing.expect(darwinProcessGroupExiting(541, std.testing.allocator, &Fake.query));
    Fake.members[1].kp_proc.p_flag = 0;
    try std.testing.expect(!darwinProcessGroupExiting(541, std.testing.allocator, &Fake.query));
    Fake.members[1].kp_proc.p_flag = c.P_SYSTEM;
    try std.testing.expect(!darwinProcessGroupExiting(541, std.testing.allocator, &Fake.query));
    Fake.members[1].kp_proc.p_stat = c.SZOMB;
    Fake.members[1].kp_proc.p_pid = 0;
    try std.testing.expect(!darwinProcessGroupExiting(541, std.testing.allocator, &Fake.query));
    Fake.members[1].kp_proc.p_pid = 542;
    Fake.members[1].kp_eproc.e_pgid = 999;
    try std.testing.expect(!darwinProcessGroupExiting(541, std.testing.allocator, &Fake.query));
    Fake.members[1].kp_eproc.e_pgid = 541;
    for ([_]Fake.Mode{ .size_failure, .data_failure, .short_size, .short_data, .oversized_size, .oversized_data, .interrupted, .growing }) |mode| {
        Fake.mode = mode;
        Fake.calls = 0;
        try std.testing.expect(!darwinProcessGroupExiting(541, std.testing.allocator, &Fake.query));
        try std.testing.expect(Fake.calls <= 6);
        if (mode == .interrupted) try std.testing.expectEqual(@as(usize, 3), Fake.calls);
        if (mode == .growing) try std.testing.expectEqual(@as(usize, 6), Fake.calls);
    }
    Fake.mode = .grow_once;
    Fake.calls = 0;
    try std.testing.expect(darwinProcessGroupExiting(541, std.testing.allocator, &Fake.query));
    try std.testing.expectEqual(@as(usize, 4), Fake.calls);
    Fake.mode = .normal;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(!darwinProcessGroupExiting(541, failing.allocator(), &Fake.query));
    Fake.count = 0;
    Fake.calls = 0;
    try std.testing.expect(darwinProcessGroupExiting(541, std.testing.allocator, &Fake.query));
    try std.testing.expectEqual(@as(usize, 2), Fake.calls);
}

test "process group signaling preserves failures for live members and accepts a zombie" {
    try requireControlledProcessTest();
    const io = std.testing.io;
    var audit: ControlledLifecycleAudit = .{};
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "while :; do sleep 1; done" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const pid = child.id.?;
    defer if (child.id != null) {
        _ = finishGroupTermination(&child, pid, .{});
        _ = reapChild(&child, io, .{}) catch {};
    };
    // Inject only the group syscall result; membership is read from the real OS.
    try std.testing.expectEqual(error.PermissionDenied, signalProcessGroup(&child, pid, .TERM, .{ .group_signal_failure = error.PermissionDenied }).?);
    try std.testing.expectEqual(error.InjectedSignalFailure, signalProcessGroup(&child, pid, .TERM, .{ .group_signal_failure = error.InjectedSignalFailure }).?);
    try std.testing.expect(signalProcessGroup(&child, pid, .TERM, .{ .group_signal_failure = error.ProcessNotFound }) == null);
    // Actual signals, never the injected failure, own fixture cleanup.
    try std.testing.expect(finishGroupTermination(&child, pid, .{ .lifecycle_audit = &audit }) == null);
    for (0..1000) |_| {
        if (try childExitedWithoutReaping(pid)) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(try childExitedWithoutReaping(pid));
    try std.testing.expect(signalProcessGroup(&child, pid, .TERM, .{ .lifecycle_audit = &audit }) == null);
    try std.testing.expect(finishGroupTermination(&child, pid, .{ .lifecycle_audit = &audit }) == null);
    _ = try reapChild(&child, io, .{ .lifecycle_audit = &audit });
    try std.testing.expectEqual(@as(usize, 1), audit.wait_calls);
    try std.testing.expectEqual(@as(usize, 1), audit.reaps);
    try std.testing.expectEqual(@as(usize, 0), audit.signal_attempts_after_reap);
}

test "controlled stdin preserves fast completion across group exit observation races" {
    try requireControlledProcessTest();
    for (0..16) |_| {
        var result = runWithStdinControlledInternal(std.testing.allocator, std.testing.io, .{
            .argv = &.{ "/bin/sh", "-c", "printf done" },
            .stdout_limit = .limited(64),
            .stderr_limit = .limited(64),
        }, .ordinary, .{}, .{ .terminate_grace = .fromMilliseconds(0) });
        defer result.deinit(std.testing.allocator);
        switch (result) {
            .completed => |captured| {
                try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, captured.ordinary.term);
                try std.testing.expectEqualStrings("done", captured.ordinary.stdout);
            },
            else => return error.ExpectedControlledCompletion,
        }
    }
}

test "process group timeout kills TERM ignoring leader and descendant and reaps direct child" {
    try requireControlledProcessTest();

    {
        var audit: ControlledLifecycleAudit = .{};
        const cooperative_argv = [_][]const u8{
            "sh",
            "-c",
            "exec 1>&- 2>&-; trap 'exit 0' TERM; while :; do :; done",
        };
        const cooperative_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
            .raw = .fromMilliseconds(200),
            .clock = .awake,
        });
        var cooperative = runCapturedControlledInternal(std.testing.allocator, std.testing.io, .{
            .argv = &cooperative_argv,
            .stdout_limit = .limited(64),
            .stderr_limit = .limited(64),
        }, .ordinary, .{ .deadline = cooperative_deadline }, .{
            .terminate_grace = .fromMilliseconds(20),
            .lifecycle_audit = &audit,
            .synchronize_final_signal_after_child_exit = true,
        });
        defer cooperative.deinit(std.testing.allocator);
        try std.testing.expect(cooperative == .timed_out);
        try std.testing.expect(audit.child_exit_observed.load(.acquire));
        try std.testing.expect(audit.signal_attempts_after_child_exit >= 2);
        try std.testing.expectEqual(@as(usize, 0), audit.signal_attempts_after_reap);
        try std.testing.expectEqual(@as(usize, 1), audit.wait_calls);
        try std.testing.expectEqual(@as(usize, 1), audit.reaps);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const argv = [_][]const u8{
        "sh",
        "-c",
        \\trap '' TERM
        \\sh -c 'trap "" TERM; printf "%s" "$$" > descendant.pid; while :; do sleep 1; done' &
        \\printf "%s" "$$" > leader.pid
        \\while :; do sleep 1; done
        ,
    };
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .raw = .fromMilliseconds(200),
        .clock = .awake,
    });
    var result = runCapturedControlledInternal(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    }, .ordinary, .{ .deadline = deadline }, .{ .terminate_grace = .fromMilliseconds(50) });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .timed_out);

    const leader_pid = try readTestPid(tmp.dir, std.testing.io, "leader.pid");
    const descendant_pid = try readTestPid(tmp.dir, std.testing.io, "descendant.pid");
    try expectProcessGone(std.testing.io, leader_pid);
    try expectProcessGone(std.testing.io, descendant_pid);
}

test "process group sensitive capture zeroizes success partial failure OOM timeout and wait failure" {
    try requireControlledProcessTest();

    {
        var audit: ZeroAuditAllocator = .{ .child = std.testing.allocator };
        const argv = [_][]const u8{ "sh", "-c", "yes secret | head -c 8192; printf diagnostic >&2" };
        var result = runCapturedControlled(audit.allocator(), std.testing.io, .{
            .argv = &argv,
            .stdout_limit = .limited(16 * 1024),
            .stderr_limit = .limited(1024),
        }, .sensitive, .{});
        switch (result) {
            .completed => |*captured| switch (captured.*) {
                .sensitive => |*sensitive| {
                    try std.testing.expect(std.mem.startsWith(u8, sensitive.stdout.bytes(), "secret"));
                    try std.testing.expectEqualStrings("diagnostic", sensitive.stderr.bytes());
                },
                .ordinary => return error.ExpectedSensitiveCapture,
            },
            else => return error.ExpectedControlledCompletion,
        }
        result.deinit(audit.allocator());
        try std.testing.expect(audit.free_count > 2);
        try std.testing.expect(!audit.observed_nonzero_free);
    }

    {
        var audit: ZeroAuditAllocator = .{ .child = std.testing.allocator };
        const argv = [_][]const u8{ "sh", "-c", "printf secretsecret" };
        var result = runCapturedControlled(audit.allocator(), std.testing.io, .{
            .argv = &argv,
            .stdout_limit = .limited(3),
            .stderr_limit = .limited(64),
        }, .sensitive, .{});
        defer result.deinit(audit.allocator());
        switch (result) {
            .failed => |failure| switch (failure) {
                .capture => |err| try std.testing.expectEqual(error.StreamTooLong, err),
                else => return error.ExpectedCaptureFailure,
            },
            else => return error.ExpectedCaptureFailure,
        }
        try std.testing.expect(audit.free_count >= 2);
        try std.testing.expect(!audit.observed_nonzero_free);
    }

    {
        var audit: ZeroAuditAllocator = .{ .child = std.testing.allocator };
        var failing = std.testing.FailingAllocator.init(audit.allocator(), .{ .fail_index = 2 });
        const argv = [_][]const u8{ "sh", "-c", "yes secret | head -c 1048576" };
        const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
            .raw = .fromMilliseconds(500),
            .clock = .awake,
        });
        var result = runCapturedControlledInternal(failing.allocator(), std.testing.io, .{
            .argv = &argv,
            .stdout_limit = .limited(2 * 1024 * 1024),
            .stderr_limit = .limited(64),
        }, .sensitive, .{ .deadline = deadline }, .{ .terminate_grace = .fromMilliseconds(10) });
        defer result.deinit(failing.allocator());
        switch (result) {
            .failed => |failure| switch (failure) {
                .capture => |err| try std.testing.expectEqual(error.OutOfMemory, err),
                else => return error.ExpectedCaptureFailure,
            },
            else => return error.ExpectedCaptureFailure,
        }
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expect(!audit.observed_nonzero_free);
    }

    {
        var audit: ZeroAuditAllocator = .{ .child = std.testing.allocator };
        const argv = [_][]const u8{ "sh", "-c", "printf secret; trap '' TERM; while :; do sleep 1; done" };
        const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
            .raw = .fromMilliseconds(50),
            .clock = .awake,
        });
        var result = runCapturedControlledInternal(audit.allocator(), std.testing.io, .{
            .argv = &argv,
            .stdout_limit = .limited(64),
            .stderr_limit = .limited(64),
        }, .sensitive, .{ .deadline = deadline }, .{ .terminate_grace = .fromMilliseconds(10) });
        defer result.deinit(audit.allocator());
        try std.testing.expect(result == .timed_out);
        try std.testing.expect(audit.free_count >= 2);
        try std.testing.expect(!audit.observed_nonzero_free);
    }

    {
        var audit: ZeroAuditAllocator = .{ .child = std.testing.allocator };
        var canceled_generation: std.atomic.Value(u64) = .init(0);
        var cancel_future = try std.testing.io.concurrent(cancellationAfter, .{
            std.testing.io,
            &canceled_generation,
            11,
        });
        defer _ = cancel_future.cancel(std.testing.io) catch {};

        const argv = [_][]const u8{ "sh", "-c", "printf secret; trap '' TERM; while :; do sleep 1; done" };
        var result = runCapturedControlledInternal(audit.allocator(), std.testing.io, .{
            .argv = &argv,
            .stdout_limit = .limited(64),
            .stderr_limit = .limited(64),
        }, .sensitive, .{ .cancellation = .{
            .canceled_generation = &canceled_generation,
            .generation = 11,
        } }, .{ .terminate_grace = .fromMilliseconds(10) });
        defer result.deinit(audit.allocator());
        try cancel_future.await(std.testing.io);
        try std.testing.expect(result == .canceled);
        try std.testing.expect(audit.free_count >= 2);
        try std.testing.expect(!audit.observed_nonzero_free);
    }

    {
        var audit: ZeroAuditAllocator = .{ .child = std.testing.allocator };
        const argv = [_][]const u8{ "sh", "-c", "printf secret" };
        var result = runCapturedControlledInternal(audit.allocator(), std.testing.io, .{
            .argv = &argv,
            .stdout_limit = .limited(64),
            .stderr_limit = .limited(64),
        }, .sensitive, .{}, .{ .wait_failure_after_reap = error.InjectedWaitFailure });
        defer result.deinit(audit.allocator());
        switch (result) {
            .failed => |failure| switch (failure) {
                .wait => |err| try std.testing.expectEqual(error.InjectedWaitFailure, err),
                else => return error.ExpectedWaitFailure,
            },
            else => return error.ExpectedWaitFailure,
        }
        try std.testing.expect(audit.free_count >= 2);
        try std.testing.expect(!audit.observed_nonzero_free);
    }

    {
        var audit: ZeroAuditAllocator = .{ .child = std.testing.allocator };
        const argv = [_][]const u8{"/definitely/not/a/gitframe-command"};
        var result = runCapturedControlled(audit.allocator(), std.testing.io, .{
            .argv = &argv,
        }, .sensitive, .{});
        defer result.deinit(audit.allocator());
        switch (result) {
            .failed => |failure| switch (failure) {
                .spawn => {},
                else => return error.ExpectedSpawnFailure,
            },
            else => return error.ExpectedSpawnFailure,
        }
        try std.testing.expectEqual(@as(usize, 0), audit.free_count);
        try std.testing.expect(!audit.observed_nonzero_free);
    }
}

test "controlled stdin drains bidirectional IO and retains the primary capture failure" {
    try requireControlledProcessTest();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const stdin = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(stdin);
    @memset(stdin, 'i');

    const success_argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "yes o | head -c 98304; yes e | head -c 98304 >&2; cat",
    };
    var success = runWithStdinControlledInternal(allocator, io, .{
        .argv = &success_argv,
        .stdin = stdin,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(128 * 1024),
    }, .ordinary, .{}, .{ .terminate_grace = .fromMilliseconds(10) });
    defer success.deinit(allocator);
    const captured = switch (success) {
        .completed => |value| switch (value) {
            .ordinary => |ordinary| ordinary,
            .sensitive => return error.ExpectedOrdinaryCapture,
        },
        else => return error.ExpectedControlledCompletion,
    };
    try std.testing.expectEqual(@as(usize, 98304 + stdin.len), captured.stdout.len);
    try std.testing.expectEqual(@as(usize, 98304), captured.stderr.len);
    try std.testing.expectEqualStrings(stdin, captured.stdout[captured.stdout.len - stdin.len ..]);

    const failure_argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "exec 0<&-; yes overflow | head -c 131072; exit 9",
    };
    var failure = runWithStdinControlledInternal(allocator, io, .{
        .argv = &failure_argv,
        .stdin = stdin,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(64),
    }, .sensitive, .{}, .{ .terminate_grace = .fromMilliseconds(10) });
    defer failure.deinit(allocator);
    switch (failure) {
        .failed => |value| switch (value) {
            .capture => |err| try std.testing.expectEqual(error.StdoutLimitExceeded, err),
            else => return error.ExpectedCaptureFailure,
        },
        else => return error.ExpectedCaptureFailure,
    }
}

test "controlled stdin empties background process groups before one final reap" {
    try requireControlledProcessTest();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var audit: ControlledLifecycleAudit = .{};
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        \\sh -c 'trap "" TERM; printf "%s" "$$" > descendant.pid; while :; do sleep 1; done' &
        \\i=0
        \\while [ ! -s descendant.pid ]; do
        \\    i=$((i + 1))
        \\    [ "$i" -lt 100 ] || exit 1
        \\    sleep 0.01
        \\done
        \\printf ok
        \\exit 0
        ,
    };
    var result = runWithStdinControlledInternal(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .dir = tmp.dir },
        .stdin = "input",
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    }, .ordinary, .{}, .{
        .terminate_grace = .fromMilliseconds(20),
        .lifecycle_audit = &audit,
    });
    defer result.deinit(allocator);
    const term = switch (result) {
        .completed => |value| switch (value) {
            .ordinary => |ordinary| ordinary.term,
            .sensitive => return error.ExpectedOrdinaryCapture,
        },
        else => return error.ExpectedControlledCompletion,
    };
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    try expectProcessGone(io, try readTestPid(tmp.dir, io, "descendant.pid"));
    try std.testing.expectEqual(@as(usize, 1), audit.wait_calls);
    try std.testing.expectEqual(@as(usize, 1), audit.reaps);
    try std.testing.expectEqual(@as(usize, 0), audit.signal_attempts_after_reap);
}

test "controlled stdin cancel and timeout kill TERM-ignoring groups" {
    try requireControlledProcessTest();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "trap '' TERM; sh -c 'trap \"\" TERM; while :; do sleep 1; done' & while :; do sleep 1; done",
    };
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(60),
        .clock = .awake,
    });
    var timed_out = runWithStdinControlledInternal(allocator, io, .{
        .argv = &argv,
        .stdin = "input",
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(64),
    }, .sensitive, .{ .deadline = deadline }, .{ .terminate_grace = .fromMilliseconds(20) });
    defer timed_out.deinit(allocator);
    try std.testing.expect(timed_out == .timed_out);
    try std.testing.expectEqual(SpawnPhase.started, timed_out.timed_out);

    var canceled_generation: std.atomic.Value(u64) = .init(27);
    var canceled = runWithStdinControlled(allocator, io, .{
        .argv = &.{"/definitely/not/a/gitframe-command"},
        .stdin = "secret",
    }, .sensitive, .{ .cancellation = .{
        .canceled_generation = &canceled_generation,
        .generation = 27,
    } });
    defer canceled.deinit(allocator);
    try std.testing.expect(canceled == .canceled);
    try std.testing.expectEqual(SpawnPhase.not_started, canceled.canceled);
}
