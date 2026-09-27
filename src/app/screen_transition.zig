//! Destination code-rain over the normal frame. No captured cells or owned text.
const std = @import("std");
const chasen = @import("chasen");
const page = @import("page.zig");

/// Update-local notification, emitted only after page-owned terminal admission.
pub const Publication = enum { none, accepted, failed };

pub const State = union(enum) {
    idle,
    waiting: page.RequestIdentity,
    running: u64,

    pub fn arm(self: *State, identity: page.RequestIdentity) void {
        self.* = .{ .waiting = identity };
    }

    /// Startup discovery changes identity before its first source publication.
    pub fn rebindStartup(self: *State, identity: page.RequestIdentity) void {
        if (self.* == .waiting) self.arm(identity);
    }

    pub fn publish(self: *State, identity: ?page.RequestIdentity, publication: Publication) bool {
        if (self.* != .waiting) return false;
        if (identity == null or !std.meta.eql(self.waiting, identity.?)) {
            _ = self.cancel();
            return false;
        }
        switch (publication) {
            .none => return false,
            .failed => {
                _ = self.cancel();
                return false;
            },
            .accepted => {
                self.* = .{ .running = 1 };
                return true;
            },
        }
    }

    /// Includes the final normal frame that removes the effect.
    pub fn step(self: *State) bool {
        if (self.* != .running) return false;
        self.running += 1;
        if (self.running >= 84) self.* = .idle;
        return true;
    }

    pub fn cancel(self: *State) bool {
        const visible = self.* == .running;
        self.* = .idle;
        return visible;
    }

    pub fn render(self: State, surface: *chasen.Surface) void {
        if (self == .running) apply(surface, self.running);
    }
};

pub fn apply(surface: *chasen.Surface, frame: u64) void {
    const progress = @min(1.0, @as(f32, @floatFromInt(frame)) / 84.0);
    applyCodeRain(surface, progress, frame);
}

const chars = [_][]const u8{ "0", "1", "3", "7", "9", "A", "B", "C", "D", "E", "F", "$", "#", "@", "%", "&", "+", "=", "░", "▒", "▓" };

fn applyCodeRain(surface: *chasen.Surface, progress: f32, frame: u64) void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    if (progress >= 1.0) return;

    var row: u16 = 0;
    while (row < size.height) : (row += 1) {
        var col: u16 = 0;
        while (col < size.width) {
            const cell = surface.readCell(col, row) orelse break;
            const width = @min(cellDisplayWidth(surface, cell), size.width - col);
            defer col += width;
            if (progress >= revealThreshold(row, col, size.height)) continue;

            // Mask the entire glyph and its background, including both cells
            // of Japanese text. Skip those cells together when revealed too.
            surface.clear(.{ .col = col, .row = row, .width = width, .height = 1 });
            if (cell.isBlank()) continue;

            // Rain characters are single-width even when replacing a wide
            // glyph; never retain the original glyph's width on replacement.
            var offset: u16 = 0;
            while (offset < width) : (offset += 1) {
                const target = col + offset;
                if (!shouldRender(progress, frame, row, target, size.height)) continue;
                surface.writeCell(target, row, .{
                    .char = .{ .grapheme = replacement(frame, row, target), .width = 1 },
                    .style = style(progress, frame, row, target, size.height),
                });
            }
        }
    }
}

fn cellDisplayWidth(surface: *const chasen.Surface, cell: chasen.Cell) u16 {
    // Width zero means backend-measured text, not a continuation cell.
    return if (cell.char.width > 0) cell.char.width else @max(surface.displayWidth(cell.char.grapheme), 1);
}

fn revealThreshold(row: u16, col: u16, height: u16) f32 {
    const height_f = @max(@as(f32, @floatFromInt(height)), 1.0);
    const row_delay = @as(f32, @floatFromInt(row)) / height_f * 0.48;
    const jitter_hash = hash(23, row, col) % 100;
    const jitter = @as(f32, @floatFromInt(jitter_hash)) / 100.0 * 0.28;
    return @min(0.96, 0.22 + row_delay + jitter);
}

fn shouldRender(progress: f32, frame: u64, row: u16, col: u16, height: u16) bool {
    const head = rainHead(progress, frame, col, height);
    const row_f = @as(f32, @floatFromInt(row));
    return row_f <= head and row_f >= head - 6.0;
}

fn style(progress: f32, frame: u64, row: u16, col: u16, height: u16) chasen.TextStyle {
    const head = rainHead(progress, frame, col, height);
    const row_f = @as(f32, @floatFromInt(row));
    if (head - row_f <= 1.0) {
        return .{ .fg = .{ .rgb = .{ 0xd8, 0xff, 0xd8 } }, .bold = true };
    }
    return .{ .fg = .{ .rgb = .{ 0x00, 0xd7, 0x5f } } };
}

fn rainHead(progress: f32, frame: u64, col: u16, height: u16) f32 {
    const height_f = @as(f32, @floatFromInt(height));
    const column_offset = @as(f32, @floatFromInt(hash(frame / 8, 0, col) % 7));
    return progress * (height_f + 10.0) - 5.0 + column_offset;
}

fn replacement(frame: u64, row: u16, col: u16) []const u8 {
    return chars[hash(frame / 5 + 41, row, col) % chars.len];
}

fn hash(frame: u64, row: u16, col: u16) usize {
    const index = @as(u32, row) *% 4099 + @as(u32, col);
    var value = frame ^ (@as(u64, index) *% 0x9e3779b97f4a7c15);
    value ^= value >> 30;
    value *%= 0xbf58476d1ce4e5b9;
    value ^= value >> 27;
    value *%= 0x94d049bb133111eb;
    value ^= value >> 31;
    return @intCast(value);
}
