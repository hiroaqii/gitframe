//! Finite resource bounds for committed-review v1 parsing and materialization.
//!
//! Byte limits count raw input/output octets, while collection limits count
//! decoded elements. These constants are contract bounds rather than tuning.

/// Independent committed-review wire schema version.
pub const schema_version: u64 = 1;
/// Maximum decoded JSON object/array nesting depth.
pub const max_json_depth: usize = 8;

// Whole-document and transient projection byte caps.
pub const max_manifest_bytes: usize = 256 * 1024;
pub const max_artifact_bytes: usize = 16 * 1024 * 1024;
pub const max_projection_bytes: usize = 16 * 1024 * 1024;

// Maximum decoded collection element counts.
pub const max_findings: usize = 4096;
pub const max_dispositions: usize = 4096;
pub const max_anchored_notes: usize = 4096;
pub const max_related_finding_ids: usize = 256;

/// Largest portable producer-observed duration in milliseconds.
pub const max_duration_ms: u64 = 4_294_967_295;

// Maximum decoded text/path byte counts; paths need not be UTF-8.
pub const max_finding_id_bytes: usize = 64;
pub const max_short_text_bytes: usize = 256;
pub const max_display_path_bytes: usize = 4096;
pub const max_raw_path_bytes: usize = 65_536;
pub const max_raw_path_encoded_bytes: usize = 87_382;
pub const max_body_bytes: usize = 65_536;

/// Largest single scanner token, sized for the encoded raw-path authority.
pub const max_json_token_bytes: usize = max_raw_path_encoded_bytes;
