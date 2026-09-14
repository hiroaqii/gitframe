//! Finite bounds for the provider-neutral AI review protocol v1.
//!
//! Byte limits count decoded or exact wire bytes as named. Collection limits
//! count decoded entries. These values are protocol contract, not tuning.

/// Independent AI review protocol schema version.
pub const schema_version: u64 = 1;

pub const max_plan_summary_bytes: usize = 16 * 1024;
pub const max_unit_bytes: usize = 256 * 1024;
pub const max_review_input_output_bytes: usize = 32 * 1024 * 1024;
pub const max_candidate_batch_bytes: usize = 256 * 1024;
pub const max_candidate_batches_bytes: usize = 16 * 1024 * 1024;
pub const max_capabilities_bytes: usize = 16 * 1024;

pub const max_projection_bytes: usize = 16 * 1024 * 1024;
pub const max_projection_frame_bytes: usize = max_projection_bytes + 2 * 1024;
pub const max_input_header_bytes: usize = 16 * 1024;
pub const max_changed_files: usize = 1024;
pub const max_hunks: usize = 8192;
pub const max_review_units: usize = 256;
pub const unit_raw_fragment_target_bytes: usize = 64 * 1024;
pub const max_diff_line_bytes: usize = 16 * 1024;
pub const max_metadata_lines_per_unit: usize = 8192;
pub const max_lines_per_unit: usize = 19_998;
pub const max_coverage_spans_per_unit: usize = 16_384;

pub const max_guidance_files: usize = 64;
pub const max_guidance_file_bytes: usize = 64 * 1024;
pub const max_guidance_aggregate_bytes: usize = 256 * 1024;
pub const max_guidance_per_unit_bytes: usize = 96 * 1024;
pub const max_guidance_path_depth: usize = 32;

pub const max_locations_per_side: usize = 9_999;
pub const max_findings_per_unit: usize = 32;
pub const max_findings_total: usize = 4096;
pub const max_title_bytes: usize = 256;
pub const max_body_bytes: usize = 16 * 1024;
pub const max_suggestion_bytes: usize = 16 * 1024;
pub const max_display_path_bytes: usize = 4096;
pub const max_raw_path_bytes: usize = 65_536;
pub const max_metadata_line_bytes: usize = 16 * 1024;
pub const max_hunk_section_bytes: usize = 4096;
pub const max_capabilities: usize = 64;
pub const max_capability_name_bytes: usize = 128;
pub const max_capability_versions: usize = 16;
pub const max_gitframe_version_bytes: usize = 256;

/// One path-free finite-limit observation propagated to the command adapter.
/// `observed` is the exact count available at the rejecting boundary; bounded
/// readers intentionally stop after observing `allowed + 1`.
pub const Violation = struct {
    resource: []const u8,
    observed: usize,
    allowed: usize,
};

pub fn record(slot: *?Violation, resource: []const u8, observed: usize, allowed: usize) void {
    slot.* = .{ .resource = resource, .observed = observed, .allowed = allowed };
}

/// One diagnostic limit echoed in every plan summary.
pub const PlanLimit = struct {
    name: []const u8,
    value: u64,
};

/// Exact v1 planning/candidate limits in canonical unsigned-byte name order.
pub const review_plan_limits = [_]PlanLimit{
    .{ .name = "body_bytes", .value = max_body_bytes },
    .{ .name = "candidate_batch_bytes", .value = max_candidate_batch_bytes },
    .{ .name = "candidate_batches_bytes", .value = max_candidate_batches_bytes },
    .{ .name = "changed_files", .value = max_changed_files },
    .{ .name = "diff_line_bytes", .value = max_diff_line_bytes },
    .{ .name = "findings_per_unit", .value = max_findings_per_unit },
    .{ .name = "findings_total", .value = max_findings_total },
    .{ .name = "guidance_aggregate_bytes", .value = max_guidance_aggregate_bytes },
    .{ .name = "guidance_file_bytes", .value = max_guidance_file_bytes },
    .{ .name = "guidance_files", .value = max_guidance_files },
    .{ .name = "guidance_path_depth", .value = max_guidance_path_depth },
    .{ .name = "guidance_per_unit_bytes", .value = max_guidance_per_unit_bytes },
    .{ .name = "hunks", .value = max_hunks },
    .{ .name = "input_header_bytes", .value = max_input_header_bytes },
    .{ .name = "input_output_bytes", .value = max_review_input_output_bytes },
    .{ .name = "projection_bytes", .value = max_projection_bytes },
    .{ .name = "projection_frame_bytes", .value = max_projection_frame_bytes },
    .{ .name = "review_units", .value = max_review_units },
    .{ .name = "suggestion_bytes", .value = max_suggestion_bytes },
    .{ .name = "title_bytes", .value = max_title_bytes },
    .{ .name = "unit_bytes", .value = max_unit_bytes },
    .{ .name = "unit_raw_fragment_target_bytes", .value = unit_raw_fragment_target_bytes },
};

test "AI review protocol planning limit names are canonical and unique" {
    const std = @import("std");
    for (review_plan_limits, 0..) |entry, index| {
        try std.testing.expect(entry.value > 0);
        if (index > 0) {
            try std.testing.expect(std.mem.order(u8, review_plan_limits[index - 1].name, entry.name) == .lt);
        }
    }
}
