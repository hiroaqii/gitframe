//! Typed namespace carried by every repository-derived Changes read.
//!
//! The scalar vocabulary lives below the Changes page owner so request,
//! tracker, task, and result modules can carry it without importing mutation
//! authority or action state. `ChangesRepositoryReadAuthority` remains the
//! only owner allowed to advance the value.

pub const ChangesRepositoryReadEpoch = struct {
    value: u64 = 1,

    pub fn eql(self: ChangesRepositoryReadEpoch, other: ChangesRepositoryReadEpoch) bool {
        return self.value == other.value;
    }

    pub fn next(self: ChangesRepositoryReadEpoch) ChangesRepositoryReadEpoch {
        var value = self.value +% 1;
        if (value == 0) value = 1;
        return .{ .value = value };
    }

    pub fn isValid(self: ChangesRepositoryReadEpoch) bool {
        return self.value != 0;
    }
};
