/// One-step vertical movement in viewport-oriented UI code.
pub const Vertical = enum {
    up,
    down,
};

/// One-step horizontal movement in viewport-oriented UI code.
pub const Horizontal = enum {
    left,
    right,
};

/// Width adjustment direction. Keep this separate from Horizontal so call
/// sites read as grow/shrink instead of right/left.
pub const Size = enum {
    shrink,
    grow,
};
