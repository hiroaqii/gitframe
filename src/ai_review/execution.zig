//! Provider-neutral limits copied into each accepted review request.
//! These runtime budgets do not replace Review Unit, Candidate, or Store limits.

const std = @import("std");

/// Leave room for a bounded reader's N+1 observation and buffer arithmetic.
pub const max_byte_limit = std.math.maxInt(usize) / 2;
/// Product ceiling for one complete provider answer, not a per-unit protocol cap.
pub const final_answer_ceiling = 256 * 1024;

pub const Key = enum {
    max_input_bytes,
    max_final_output_bytes,
    max_stream_output_bytes,
    timeout_seconds,
};

pub const Reason = enum {
    integer_required,
    positive_required,
    out_of_range,
    final_ceiling,
    stream_smaller_than_final,
    duplicate,
};

pub const InvalidSetting = struct { key: Key, reason: Reason };

pub const Limits = struct {
    max_input_bytes: usize = 1024 * 1024,
    max_final_output_bytes: usize = final_answer_ceiling,
    max_stream_output_bytes: usize = 8 * 1024 * 1024,
    timeout_seconds: u32 = 1800,

    pub fn validate(self: Limits) ?InvalidSetting {
        inline for (.{ Key.max_input_bytes, Key.max_final_output_bytes, Key.max_stream_output_bytes, Key.timeout_seconds }) |key| {
            if (@field(self, @tagName(key)) == 0) return .{ .key = key, .reason = .positive_required };
        }
        if (self.max_input_bytes > max_byte_limit) return .{ .key = .max_input_bytes, .reason = .out_of_range };
        if (self.max_final_output_bytes > final_answer_ceiling) return .{ .key = .max_final_output_bytes, .reason = .final_ceiling };
        if (self.max_stream_output_bytes > max_byte_limit) return .{ .key = .max_stream_output_bytes, .reason = .out_of_range };
        if (self.max_stream_output_bytes < self.max_final_output_bytes) return .{ .key = .max_stream_output_bytes, .reason = .stream_smaller_than_final };
        return null;
    }

    /// Starts immediately before the version probe; the same absolute deadline
    /// covers the main provider process. Queue/preparation/decode are excluded.
    pub fn timeout(self: Limits) std.Io.Duration {
        return .fromSeconds(self.timeout_seconds);
    }
};

test "AI review execution limits have common defaults and finite ranges" {
    const defaults: Limits = .{};
    try std.testing.expect(defaults.validate() == null);
    try std.testing.expectEqual(@as(usize, 1048576), defaults.max_input_bytes);
    try std.testing.expectEqual(@as(usize, 262144), defaults.max_final_output_bytes);
    try std.testing.expectEqual(@as(usize, 8388608), defaults.max_stream_output_bytes);
    try std.testing.expectEqualDeep(std.Io.Duration.fromSeconds(1800), defaults.timeout());
    inline for (.{ Key.max_input_bytes, Key.max_final_output_bytes, Key.max_stream_output_bytes, Key.timeout_seconds }) |key| {
        var invalid = defaults;
        @field(invalid, @tagName(key)) = 0;
        try std.testing.expectEqualDeep(InvalidSetting{ .key = key, .reason = .positive_required }, invalid.validate().?);
    }
    const cases = [_]struct { value: Limits, invalid: InvalidSetting }{
        .{ .value = .{ .max_input_bytes = max_byte_limit + 1 }, .invalid = .{ .key = .max_input_bytes, .reason = .out_of_range } },
        .{ .value = .{ .max_final_output_bytes = final_answer_ceiling + 1 }, .invalid = .{ .key = .max_final_output_bytes, .reason = .final_ceiling } },
        .{ .value = .{ .max_stream_output_bytes = max_byte_limit + 1 }, .invalid = .{ .key = .max_stream_output_bytes, .reason = .out_of_range } },
        .{ .value = .{ .max_stream_output_bytes = 1 }, .invalid = .{ .key = .max_stream_output_bytes, .reason = .stream_smaller_than_final } },
    };
    for (cases) |case| try std.testing.expectEqualDeep(case.invalid, case.value.validate().?);
    const smallest: Limits = .{ .max_input_bytes = 1, .max_final_output_bytes = 1, .max_stream_output_bytes = 1, .timeout_seconds = 1 };
    const largest: Limits = .{ .max_input_bytes = max_byte_limit, .max_stream_output_bytes = max_byte_limit, .timeout_seconds = std.math.maxInt(u32) };
    try std.testing.expect(smallest.validate() == null);
    try std.testing.expect(largest.validate() == null);
    try std.testing.expectEqual(@as(i96, std.math.maxInt(u32)) * std.time.ns_per_s, largest.timeout().nanoseconds);
}
