//! Deterministic capacity diagnostic for Repository full-file syntax metadata.
//!
//! The command shares the production flow-syntax capture and line sanitizer,
//! but allows final metadata to grow to a finite source-derived ceiling so it
//! can explain whether the current production span or byte limit would reject
//! the file. It does not bound provider-emitted raw candidates or per-line
//! sanitizer temporaries beyond their existing production behavior, and it is
//! neither a performance benchmark nor a CI acceptance gate.
//!
//! Usage:
//!   zig build source-syntax-capacity -- <file>

const std = @import("std");
const content_fingerprint = @import("../content_fingerprint.zig");
const selected_document = @import("../repository/document.zig");
const source_document = @import("../repository/source.zig");
const source_adapter = @import("../syntax/source_flow_syntax.zig");
const source_spans = @import("../syntax/source.zig");
const token = @import("../syntax/token.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: zig build source-syntax-capacity -- <file>\n", .{});
        return error.InvalidArguments;
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        init.gpa,
        .limited(selected_document.max_text_bytes),
    );
    var document = try source_document.Document.initOwnedOrFree(
        init.gpa,
        bytes,
        content_fingerprint.Fingerprint.init(bytes),
    );
    defer document.deinit(init.gpa);
    const report = try source_adapter.inspectSourceCapacity(init.gpa, init.io, &document, args[1]);
    printReport(args[1], report);
}

fn printReport(path: []const u8, report: source_adapter.CapacityReport) void {
    std.debug.print(
        \\GitFrame Repository source syntax capacity
        \\  file: {s}
        \\  source bytes: {d}
        \\  content lines: {d}
        \\  raw candidates: {d}
        \\  retained entries: {d}
        \\  retained spans: {d}
        \\  retained bytes: {d}
        \\  diagnostic entry ceiling: {d}
        \\  diagnostic span ceiling: {d}
        \\  diagnostic byte ceiling: {d}
        \\  production span limit: {d}
        \\  production byte limit: {d}
        \\  production decision: {s}
        \\  roles (raw / retained):
        \\
    , .{
        path,
        report.source_bytes,
        report.content_lines,
        report.raw_candidates,
        report.retained_entries,
        report.retained_spans,
        report.retained_bytes,
        report.diagnostic_limits.entries orelse unreachable,
        report.diagnostic_limits.spans,
        report.diagnostic_limits.bytes,
        source_spans.max_spans,
        source_spans.max_retained_bytes,
        @tagName(report.production_decision),
    });
    inline for (@typeInfo(token.TokenRole).@"enum".fields, 0..) |field, index| {
        std.debug.print("    {s}: {d} / {d}\n", .{
            field.name,
            report.raw_roles[index],
            report.retained_roles[index],
        });
    }
}
