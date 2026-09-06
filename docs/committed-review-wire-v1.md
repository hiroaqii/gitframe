# Committed review contract v1

This document defines GitFrame's provider-neutral contract for reviewing an exact committed revision pair. It covers portable artifacts, local Git materialization, and the two installed process commands consumed by downstream automation. It does not define durable Store mechanics, provider-specific publication payloads, or AI Review, Stream, or History UI.

Machine-local binding, immutable Run publication, and history admission are defined separately by [`ai-review-store-v1.md`](./ai-review-store-v1.md); they do not add path or repository identity to this portable wire authority.

## Authority model

The portable authorities are:

- `CommittedReviewTarget`: the object format, source kind, and exact base, head, and diff-base commit OIDs.
- `CodeAnchor`: exact raw path bytes, target side, 1-based inclusive line range, and the SHA-256 digest of the selected committed blob bytes.
- The canonical committed-review artifacts that carry those values and their exact-byte digests.

The following are local, transient, and non-authoritative:

- materialized patch bytes;
- hunk boundaries, context lines, and rename projection;
- ahead counts and display labels;
- rendered rows, cursor positions, patch positions, and Stream-global rows;
- physical repository device/inode locators.

GitFrame does not promise byte-identical patch projection between machines, Git versions, or local Git configurations. Patch bytes are still exact within one successful materialization and are transported without normalization.

## Target identity

A target has exactly five fields in this canonical writer order:

```json
{"object_format":"sha1","source_kind":"branch_range","base_oid":"0000000000000000000000000000000000000000","head_oid":"1111111111111111111111111111111111111111","diff_base_oid":"0000000000000000000000000000000000000000"}
```

- `object_format` is `sha1` or `sha256`; all three OIDs are respectively 40 or 64 lowercase hexadecimal bytes.
- `source_kind` is `branch_range` in v1. It records target construction semantics, not a Review-page mode.
- `base_oid` is the commit selected by caller base policy.
- `head_oid` is the exact reviewed commit and the source tree for versioned `.gitattributes`.
- `diff_base_oid` is the exact-one best merge base and is the left projection endpoint. It may differ from `base_oid`.

Target equality is structural equality of those five fields. Repository identity, refs, labels, ahead count, patch bytes, producer, and process state are excluded.

`resolveTarget(input)` ends successfully as soon as it has pinned base and head commits and one best merge base. Ahead display, projection, and anchor reads are separate operations with separate complete-success/failure results. A missing blob or an oversized future projection therefore cannot change a successful target result when the required commit graph is locally available.

## Closed commit-ish grammar

The strict resolver accepts a code-defined closed language. Configuration cannot extend it with regular expressions, resolver commands, index selectors, or arbitrary Git expressions.

The v1 base token may identify:

- a full or unambiguous abbreviated object ID;
- an allowed full ref under the explicitly handled `refs/*` namespaces;
- a valid ref or tag candidate admitted by the resolver;
- a one-level root/pseudo-ref atom such as `HEAD` or `FETCH_HEAD`.

The only suffixes are explicitly parsed parent/ancestor operations (`^`, `^N`, `~N`) and commit peel forms (`^{}` and `^{commit}`). Each input is at most 4,096 bytes, has at most 64 suffixes, and numeric suffixes are canonical decimal in `0...65535`.

Ranges and sets (`A..B`, `A...B`, `^A`), reflogs, index selectors, message/path selectors, describe fallback, unlisted peel forms, whitespace/control input, and any other extended SHA are rejected. A caller that needs an advanced Git expression must resolve it under its own explicit policy and pass the resulting full commit OID.

Root/pseudo-ref probing is limited to one atom without `/`. A slash-containing name is handled only as an explicitly admitted ref namespace; it is never probed as an arbitrary `$GIT_DIR/<name>` path. Root-ref files are read through a no-follow regular-file descriptor path with bounded records.

User configuration may choose a default base, named target, or display label. It must ultimately pass an allowed full ref or exact OID to the strict resolver and cannot change the core grammar.

## Strict local Git reads

Every strict object read uses the shared prefix:

```text
git --no-replace-objects --no-lazy-fetch --no-optional-locks
```

Committed projection additionally disables external diff and text conversion. It uses Git's `--attr-source=<head_oid>` so versioned attributes come from the committed head tree.

The strict read path never fetches, invokes credential or remote helpers, or writes the object database. Unsupported `--no-lazy-fetch` or `--attr-source`, a missing promisor object, invalid internal Git configuration, child failure/signal, and stderr overflow close in the owning operation's bounded failure taxonomy. Git stderr text and locale are diagnostic only; they do not select a machine-readable error code, retry, fetch, or artifact result.

Working-tree, index, staged, and untracked file bytes—including `.gitattributes`—are not projection input. `.git/info/attributes`, global/system attributes, and internal Git diff/config policy may affect the local non-authoritative projection. External diff, textconv, replace objects, and lazy fetch remain disabled.

## Operation-specific results

The four Git read operations do not share a generic `target_unavailable` result:

- `resolveTarget` returns a complete `CommittedReviewTarget` or a target-resolution failure.
- `computeAheadDisplay` returns a display-only count or an ahead-graph failure.
- `materializeCommittedProjection` returns a complete target plus allocator-owned patch bytes, or `projection_too_large` / `projection_git_command_failed`.
- `resolveCodeAnchor` returns the exact blob OID plus allocator-owned selected bytes, or an anchor-specific validation/object-read failure.

Only Git diff stdout crossing 16 MiB maps to `projection_too_large`. All other projection Git/process failures map to `projection_git_command_failed`. Projection performs no custom object-availability preflight or custom tree/blob traversal.

## Code anchors

`path_bytes_b64` is canonical unpadded base64url of lossless repository-relative Git path bytes. `display_path`, when present, is a safe UTF-8 label and is never used to locate or retarget content.

`side=before` selects the `diff_base_oid` tree; `side=after` selects the `head_oid` tree. `start_line` and `end_line` are 1-based and inclusive. The `content_digest` is SHA-256 over the exact selected committed blob bytes, including original line endings and a final LF when it belongs to the selected range. `quoted_text` is optional producer context, not authority.

Anchors store no hunk number, patch position, rendered row, or provider line placement. Failure never falls back to a similar path, nearby line, or working-tree content.

## Artifact ownership

All four v1 artifacts use strict JSON: unknown or duplicate fields, missing required fields, explicit `null` aliases, non-canonical IDs/OIDs/digests, and values over finite bounds are rejected. Parsers return one owner whose arena backs all decoded string and slice fields. Canonical writers emit compact JSON in fixed field order followed by one LF.

- `findings.json` is producer-owned immutable output.
- `manifest.json` is producer-owned immutable binding metadata.
- `review_state.json` is GitFrame-owned mutable draft state before a terminal result.
- `result.json` is GitFrame-owned immutable terminal state.

`findings_digest` hashes the exact stored `findings.json` bytes from first byte through final byte, including whitespace, escape representation, field order, and final LF. It is not a semantic reserialization digest.

All findings remain in draft and result state regardless of whether a provider can place them inline.

### Final v1 artifact fields

This is a pre-release correction to schema version 1. Readers accept only the final field model below. They do not default missing fields, accept compatibility aliases, migrate older private artifacts, or expose a dual writer.

Canonical top-level writer order is fixed:

| Artifact | Fields |
| --- | --- |
| `findings.json` | `schema_version`, `review_id`, `created_at`, optional `timing`, `target`, `producer`, `findings` |
| `manifest.json` | `schema_version`, `review_id`, `review_repository_id`, `target`, `created_at`, optional `display`, `finding_count`, `producer`, `findings_digest` |
| `review_state.json` | `schema_version`, `review_id`, `target`, `findings_digest`, `revision`, optional `summary`, `finding_dispositions`, `anchored_notes` |
| `result.json` | `schema_version`, `review_id`, `target`, `findings_digest`, `result`, `completed_at`, optional `summary`, `finding_dispositions`, `anchored_notes` |

`producer.name` identifies the agent product that performed the semantic
review, rather than an orchestration Skill or GitFrame itself. Optional
`producer.model` and `producer.version` identify that agent execution only when
their exact values are known. Optional `producer.skill_version` independently
identifies the orchestration Skill release. Producers omit unknown optional
values rather than inferring or substituting unrelated component versions.

`FindingSet.created_at` is required. It is the UTC second at which the producer completed one immutable FindingSet, in the exact RFC 3339 form `YYYY-MM-DDTHH:MM:SSZ`. The producer obtains it once and writes the same string to `findings.json` and `manifest.json`. The manifest copy is a lightweight history-index projection; cross-artifact admission requires byte-for-byte equality and reports a projection mismatch separately from a digest mismatch. A publish retry for one immutable Run retains the original findings bytes and timestamp. Rerunning review creates a new review ID and timestamp.

`created_at` is provenance and display metadata. It is not review-request time, Store publication time, human decision time, target identity, anchor placement, or authorization authority. History ordering remains based on manifest `created_at`.

`FindingSet.timing` is optional. Its only v1 field is required `duration_ms`, an unsigned canonical JSON integer in `0...4294967295`. Absence means measurement is unavailable; zero is a valid measured duration and is never an unavailable sentinel. The value is producer-observed workflow provenance. It is not model self-report, a timeout or billing authority, or a value inferred from timestamps or filesystem metadata. Timing is not projected into the manifest. When present, its exact bytes are naturally covered by `findings_digest`.

Both `FindingSet.created_at` and `RevisionReviewResult.completed_at` use the same strict Gregorian UTC-seconds validator. Missing values, explicit `null`, wrong JSON types, timezone offsets, fractional seconds, leap seconds, year zero, and impossible calendar dates are invalid. The codec validates caller-supplied values and never reads a clock or repairs a timestamp.

`ReviewDraftState.anchored_notes` is required, including the canonical empty array when no note exists. Notes are mutable human work under the same positive draft `revision` as summary and dispositions. Draft parsing and canonical writing preserve the complete array across resume; no note-specific revision or frozen flag exists.

`RevisionReviewResult.completed_at` is required and is the human terminal-decision completion time. The future Store mutation owner supplies it from a trusted clock only after admitting an explicit submit attempt. It is not derived from manifest time, directory names, or filesystem mtime, and it does not change history ordering. A failed publication creates no valid result; a later admitted retry may use a new completion timestamp.

### Draft, result, and note admission

Draft and result notes share the same structural validation: at most 4,096 notes, a structurally valid `CodeAnchor`, a non-empty bounded body, and at most 256 unique bounded related Finding IDs per note. Cross-artifact validation additionally requires the artifact review ID, complete target, and exact findings digest to match the admitted FindingSet, and every related ID to exist in that FindingSet. Invalid notes reject the complete artifact; readers do not drop individual notes.

Wire validation deliberately does not read Git. A consumer admits each structurally valid note anchor by calling the existing `resolveCodeAnchor(target, anchor)` operation. That operation alone proves the raw path, selected side, committed blob, inclusive line range, and content digest against the already bound exact target. A foreign but structurally valid anchor therefore passes JSON decoding and fails Git-backed admission without retargeting.

A terminal result is a self-contained immutable snapshot. Submit validation first admits both draft and result against the same FindingSet and exact digest, then requires exact equality of:

- optional summary presence and bytes;
- disposition array length, order, Finding IDs, and values;
- anchored-note array length and order, every complete anchor, body bytes, and related-ID sequence.

`result` and `completed_at` are terminal fields and are not part of draft equality. Summary, disposition, and anchored-note loss have distinct typed snapshot failures. Interpreting a result never requires reopening the retained draft file.

### Store-neutral run state

The artifact domain exposes only a pure admission state derived from already validated artifact evidence:

| Valid draft | Valid result | Derived state | Draft create/update | Result create |
| --- | --- | --- | --- | --- |
| no | no | `new` | admitted | `DraftRequired` |
| yes | no | `draft` | admitted | admitted after snapshot validation |
| no or yes | yes | `completed` | `AlreadyCompleted` | `AlreadyCompleted` |

A submit owner must save and validate the latest draft before create-once result publication. Valid result presence is the terminal authority even when the frozen draft remains stored. Raw invalid-file presence is not valid result evidence. A failed publication leaves the prior valid draft editable and does not serialize cancellation or completion. `canceled` is produced only by an explicit terminal submit and follows the same snapshot and create-once rules. Normal Review return, picker close, page or repository transition, and quit do not synthesize a result.

Filesystem scanning, regular-file/no-follow admission, locking, draft CAS, atomic save, create-once publication, clock acquisition, mutation serialization, and crash recovery are outside this wire contract.

## Installed target command

The target-only command is part of the normal `gitframe` executable:

```text
gitframe review-target \
  --repository <absolute-path> \
  --source-kind branch_range \
  --base <commit-ish> \
  --head <commit-ish>
```

Each option appears exactly once and has one value of 1...4,096 bytes. Unknown, duplicate, missing, positional, or option-like values fail with `invalid_arguments`. The command is dispatched by its exact first token before global help scanning, config loading, terminal setup, TUI startup, or Store access. Consequently `review-target --help` is a versioned `invalid_arguments` terminal; `gitframe --help` retains normal human help.

Success is one compact JSON document plus LF:

```json
{"schema_version":1,"status":"ok","target":{"object_format":"sha1","source_kind":"branch_range","base_oid":"0000000000000000000000000000000000000000","head_oid":"1111111111111111111111111111111111111111","diff_base_oid":"0000000000000000000000000000000000000000"}}
```

Failure has no partial target:

```json
{"schema_version":1,"status":"error","error":{"code":"no_merge_base","message":"base and head have no merge base"}}
```

Exit allocation is:

| Exit | Codes |
| --- | --- |
| 0 | `status=ok` |
| 2 | `invalid_arguments`, `unsupported_source_kind`, `unsupported_base_commitish`, `unsupported_head_commitish` |
| 3 | `invalid_repository`, `unsupported_object_format`, `unresolved_base`, `unresolved_head`, `ambiguous_base`, `ambiguous_head`, `non_commit_base`, `non_commit_head`, `object_unavailable_base`, `object_unavailable_head`, `target_graph_unavailable` |
| 4 | `no_merge_base`, `ambiguous_merge_base` |
| 5 | `git_command_failed` |
| 70 | `internal_error` or output transport failure |

The command calls only `resolveTarget`; it never computes ahead, projection, or anchor data.

## Installed projection command

The separate command accepts no options or positional arguments:

```text
gitframe review-projection
```

It reads one strict JSON document from stdin, up to 8 KiB, with optional one final LF:

```json
{"schema_version":1,"repository":{"path_bytes_b64":"L3RtcC9yZXBv"},"target":{"object_format":"sha1","source_kind":"branch_range","base_oid":"0000000000000000000000000000000000000000","head_oid":"1111111111111111111111111111111111111111","diff_base_oid":"0000000000000000000000000000000000000000"}}
```

The repository value is canonical unpadded base64url of an absolute POSIX path containing 1...4,096 raw non-NUL bytes. The target must contain all five structurally valid target fields. Commit-ish, ref, default base, merge-base policy, repository ID, labels, ahead, and anchor inputs are not accepted. The adapter opens the explicit repository and calls `materializeCommittedProjection(target)` exactly once. It does not resolve refs or reproduce Git diff policy.

Success stdout is a canonical header (including LF at most 2 KiB) immediately followed by exactly `patch_size` uninterpreted bytes:

```text
{"schema_version":1,"status":"ok","target":{...},"patch_size":123}<LF>
<exactly 123 patch bytes>
```

`patch_size` is canonical unsigned decimal in `0...16777216`. The patch is not required to be UTF-8 and no line-ending or final-LF transformation occurs. The complete patch and bounded header are materialized before stdout begins.

Failure stdout is a canonical error header plus LF and EOF, at most 4 KiB, with no target, `patch_size`, or patch payload:

```json
{"schema_version":1,"status":"error","error":{"code":"projection_git_command_failed","message":"committed projection could not be materialized"}}
```

Exit allocation is:

| Exit | Codes |
| --- | --- |
| 0 | complete success frame |
| 2 | `invalid_arguments`, `invalid_request`, `unsupported_schema_version`, `invalid_target` |
| 3 | `invalid_repository` |
| 4 | `projection_too_large` |
| 5 | `projection_git_command_failed` |
| 70 | `internal_error` or output transport failure |

A consumer admits success only when exit is 0, the first LF is within the header cap, the strict header target equals the request target, exactly `patch_size` bytes follow, and EOF follows the payload. It rejects unknown/duplicate fields, short or extra payload, a mismatched target, and any nonzero exit. It admits an error only when the code matches the nonzero exit and LF is followed immediately by EOF. If stdout transport fails after writing begins, exit 70 and these admission rules make the truncated prefix invalid.

## Downstream use

#106 obtains a target with the installed `review-target` command, places that exact complete target in `review-projection`, validates the frame, and uses the returned payload as generation input. It must not run raw `git diff`, reimplement projection policy, fetch, or fall back after request/frame failure. Both commands must come from the same installed GitFrame binary/version.

Current Branch Review resolves current `HEAD` against the base selected with `m` and uses the same page-neutral committed projection. A future pinned AI Review Run uses its stored exact OID target and does not allow `m` to retarget it. These are modes of the same Review page/diff surface, not duplicated pages.

#111 File/Stream views and future History reuse the same committed projection and renderer foundations. Stream rows, hunk positions, and cursor coordinates remain runtime presentation state, not durable authority. This contract does not implement those UIs.

## Provider publication

Provider-specific publication is owned by its consumer (for example #67), not by these commands. Immediately before publication, the consumer validates the current PR base/head/diff, exact target, raw path, committed blob, line range, and content digest.

Only a finding with a unique exact current-diff placement may become an inline comment. A still-valid finding that cannot satisfy provider inline constraints is explicitly downgraded to a file-level comment or review summary. A target or digest mismatch, ambiguous path, or stale PR aborts publication of the review. Automatic retargeting to a similar path or nearby line is forbidden.
