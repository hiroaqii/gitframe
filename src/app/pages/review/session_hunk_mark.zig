//! Typed Review-local effects for session-staged hunk presentation marks.
//!
//! The repository root and path remain owned once by the surrounding hunk
//! target/task/result. This module carries only scalar presentation lineage and
//! the display hunk ordinal, so async ownership never duplicates path buffers.

const review_selection = @import("../../diff_surface/selection.zig");

pub const Key = struct {
    content: review_selection.ReviewContentToken,
    display_hunk_index: usize,

    pub fn eql(self: Key, other: Key) bool {
        return self.display_hunk_index == other.display_hunk_index and
            self.content.eql(other.content);
    }
};

/// Review-local consequence applied only after the Git action is accepted.
///
/// Patch authority is resolved independently before task launch. In
/// particular, a session mark never grants permission to stage or unstage.
pub const Mutation = union(enum) {
    none,
    add: Key,
    remove: Key,
};
