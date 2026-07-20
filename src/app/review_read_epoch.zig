//! Typed namespace carried by every repository-derived Review read.
//!
//! The scalar vocabulary lives below the Review page owner so request,
//! tracker, task, and result modules can carry it without importing mutation
//! authority or action state. `ReviewRepositoryReadAuthority` remains the
//! only owner allowed to advance the value.

pub const ReviewRepositoryReadEpoch = struct {
    value: u64 = 1,

    pub fn eql(self: ReviewRepositoryReadEpoch, other: ReviewRepositoryReadEpoch) bool {
        return self.value == other.value;
    }

    pub fn next(self: ReviewRepositoryReadEpoch) ReviewRepositoryReadEpoch {
        var value = self.value +% 1;
        if (value == 0) value = 1;
        return .{ .value = value };
    }

    pub fn isValid(self: ReviewRepositoryReadEpoch) bool {
        return self.value != 0;
    }
};
