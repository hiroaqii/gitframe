# AI review producer protocol v1

This document defines the provider-neutral protocol and deterministic input
materializer used by the portable `gitframe-ai-review` Skill. The current
input materializer does not invoke an AI, mutate the Review Store, publish a
Run, install a Skill, or read a human result. Human-result retrieval is a
separate exact-ID helper described below.

## Authority boundary

GitFrame's deterministic helpers own the committed target, projection and
instruction digests, unit construction, raw paths, location mapping, coverage,
stored batch envelope, anchors, artifacts, Store mutation, and publication.
The AI supplies only one `FindingCandidatePayload` for the currently issued
unit. Repository guidance is advisory semantic input and cannot add fields or
change any deterministic value.

Every protocol document is compact UTF-8 JSON in the field order below,
followed by exactly one LF and EOF. Parsers reject unknown, duplicate, missing,
`null`, out-of-order/noncanonical, over-limit, invalid UTF-8, extra-byte, and
unsupported-schema input. Raw Git paths use canonical unpadded base64url and
need not be UTF-8. Digests use `sha256:` plus 64 lowercase hexadecimal digits.

The fixture directories
[`testdata/ai-review-producer-v1/protocol`](../testdata/ai-review-producer-v1/protocol)
and [`testdata/ai-review-producer-v1/input`](../testdata/ai-review-producer-v1/input)
contain exact canonical documents and bounded patch cases.

## Capability handshake

`gitframe review-capabilities` takes no arguments, does not read stdin, and
does not open a repository, config, Store, TUI, or installation state. Success
is one `CapabilityResponse`:

```json
{"schema_version":1,"status":"ok","gitframe_version":"0.0.0","capabilities":[{"name":"ai-review.input","versions":[1]},{"name":"ai-review.producer","versions":[1]},{"name":"committed-review.artifact","versions":[1]},{"name":"committed-review.instructions","versions":[1]},{"name":"committed-review.projection","versions":[1]},{"name":"committed-review.target","versions":[2]},{"name":"review-store.prepare","versions":[1]},{"name":"review-store.publish","versions":[1]},{"name":"review-store.result-read","versions":[1]}]}
```

Capability names are strictly increasing by unsigned UTF-8 bytes. Each
versions array is non-empty, positive, strictly increasing, and unique.
Compatibility is exact name/version membership; GitFrame semver is diagnostic
only and a future-only version does not satisfy a required version.

The installed producer release advertises exactly, in order:

1. `ai-review.input@1`
2. `ai-review.producer@1`
3. `committed-review.artifact@1`
4. `committed-review.instructions@1`
5. `committed-review.projection@1`
6. `committed-review.target@2`
7. `review-store.prepare@1`
8. `review-store.publish@1`
9. `review-store.result-read@1`

`ai-review.producer@1` names only the installed read-only artifact command
below. `review-store.result-read@1` separately names the exact human-result
reader; neither capability implies Skill installation, retry, recovery, or a
provider capability.

The bundled Skill requires `committed-review.target@2` and the other seven
production/publication capabilities at v1. It strictly validates capability
entry shape, order, names, and increasing integer versions. Target success has
the exact schema-v2 order `schema_version`, `status`, `target`, `display`; the
display object always contains nullable `base_label` then `head_label` under
the existing 256-byte single-line text bound.

Any argument, including `--help`, returns exit 2 and a bounded canonical error
line. Allocation/internal failure returns exit 70. Successful output is capped
at 16 KiB.

## Exact human result reader

`gitframe review-result-read` is a one-shot, no-write helper for one canonical
Review ID. It accepts the same strict v1 request as `review-store-read`: an
absolute repository encoded as canonical padded RFC 4648 standard Base64, the
exact `review_id`, and an optional complete expected publication identity. The
request is capped at 16 KiB and the decoded repository path at 4,096 bytes.

GitFrame freshly resolves the physical repository binding and configured
Store, admits only the named Run, validates its manifest, findings, draft/result
precedence and target objects, and revalidates concurrent snapshots. It never
enumerates a namespace, selects newest/mtime/target alternatives, starts the
TUI, polls, retries, or mutates Git or the Store.

A valid Run without a result returns exit 0 and one compact `pending` header
line. A valid result returns exit 0 and one compact `completed` header line,
immediately followed by the exact canonical `result.json` bytes (including
their final LF):

```text
pending:   status, schema_version, review_repository_id, review_id, target,
           findings_sha256, finding_count, LF, EOF
completed: the same fields, result_sha256, result_size, LF,
           exactly result_size payload bytes, EOF
```

The header is capped at 16 KiB and the payload at the committed-review 16 MiB
artifact bound. `result_sha256` binds every payload byte; the admitted result's
review ID, target, and findings digest are cross-validated before output. A
missing or invalid Run, unavailable target, expectation mismatch, invalid
binding/Store, or concurrent change is a bounded path-free JSON error line with
nonzero exit and no payload. Exact request, header, and payload examples live in
[`testdata/ai-review-result-reader-v1`](../testdata/ai-review-result-reader-v1).

## Plan summary

`ReviewPlanSummary` fields are:

```text
schema_version
target
projection_digest
instruction_set_digest
unit_count
plan_digest
limits
```

The target is the existing five-field `CommittedReviewTarget`. `unit_count` is
`0...256`; zero is available to the deterministic no-change terminal and does
not issue a Review ID. `limits` is an array of exact `{name,value}` pairs. The
parser admits only the complete v1 array and order emitted by the writer, so a
plan cannot silently weaken a bound.

The v1 planning entries cover the 16 MiB projection and projection-frame cap,
1,024 files, 8,192 hunks, 256 units/model turns, 64 KiB unit fragment, 16 KiB
line, 256 KiB unit, 32 MiB complete input output, committed-guidance limits,
32 findings per unit/4,096 total, semantic text limits, and candidate batch
limits. The canonical fixture is [`plan.json`](../testdata/ai-review-producer-v1/protocol/plan.json).

The guidance file ceiling is 64 unique `(head_oid, raw AGENTS.md path)` keys
across the complete plan. The input materializer owns that global union,
its 256 KiB unique-content aggregate, and one exact source record per key. A
repeated key in any unit must carry the same blob OID, content digest, and exact
content bytes.

## Review unit and locations

`ReviewUnit` fields are:

```text
schema_version
plan_digest
unit_id
ordinal
unit_count
old_path_bytes_b64? / new_path_bytes_b64?
display_path
file_status
metadata_lines
hunks
locations
before_guidance / after_guidance
coverage_spans
```

Unit IDs are exactly `unit-0001...unit-0256`, equal the 1-based ordinal,
and the ordinal cannot exceed `unit_count`. File status is one of `added`,
`modified`, `deleted`, `renamed`, or `copied`; required old/new paths and path
equality/difference are checked for that status. Display paths are bounded
human labels and never path authority.

Each hunk records old/new start and count, optional section, and every content
line. A line has `kind=context|removed|added`, UTF-8 `text` without diff prefix
or terminator, and `line_ending=lf|crlf|none`. This preserves CRLF and missing
final-LF semantics without placing control bytes in line text. Context lines
carry both before and after location IDs; removed lines only before; added
lines only after. Hunk counts and exact source coordinates are validated.
Successive hunk spans are strictly source-ordered and non-overlapping on both
sides. A zero-count range is the boundary after its start coordinate (zero is
before line one), and no later line on a side may follow `line_ending=none`.

Locations are ordered as all before locations then all after locations. IDs
are contiguous `b0001...b9999` and `a0001...a9999`; each repeats the raw path,
side, and positive committed line owned by the helper. Every location is
referenced exactly once by the ordered hunk lines. This makes an opaque ID
useful to the AI without giving it authority to choose a path or line.

Each guidance item carries exact head/blob object IDs, raw `AGENTS.md` path,
content digest, and unchanged bounded UTF-8 content. Before and after chains
are separate and root-to-leaf; both are exact-head advisory input. The codec
requires one common head OID, canonical repository-relative `AGENTS.md` paths,
strict ancestor order, and `content_digest = SHA-256(exact content bytes)`.
The before chain is bound to the old path and the after chain to the new path;
an absent side requires an empty chain, and every item must be root guidance or
a strict directory ancestor of that side's file path. Target parent-directory
depth is at most 32 (so a chain may contain root plus 32 nested entries), with
at most 64 unique keys in the union of this unit's before/after chains. The
unit codec rejects conflicting records for a repeated key. This local check
is complemented by the complete-plan limit owned by `review-input`. The
96 KiB per-unit content bound counts the bytes serialized in both chains,
including repeated occurrences, because it bounds the actual unit input.

Coverage spans are sorted non-overlapping half-open offsets into the exact
projection payload. Their summed bytes are nonzero and at most 64 KiB. They
are diagnostic coverage authority, not AI-selected location authority. The
canonical complete example is [`unit.json`](../testdata/ai-review-producer-v1/protocol/unit.json).

The 256 KiB canonical-unit cap is checked independently of collection identity
ceilings. Some theoretical maximum-cardinality arrays (for example 8,192
hunks or 9,999 locations on one side) necessarily reach the wire cap first;
their exact cardinality closes as `ArtifactTooLarge`, while cardinality plus
one closes as `LimitExceeded`. No writer truncates an array to fit.

## Candidate payload and stored batch

The only AI-authored document is:

```json
{"findings":[{"start_location":"a0002","end_location":"a0003","severity":"warning","title":"...","body":"...","suggestion":"..."}]}
```

`suggestion` is optional; all other finding fields are required. Findings are
capped at 32 per unit. Start and end must use the same side and ascend by
location ordinal. Title is at most 256 bytes; body and suggestion are at most
16 KiB each. Semantic text is non-empty valid UTF-8 and rejects terminal
controls. An empty findings array explicitly completes semantic review of the
unit.

The deterministic helper wraps that payload as a `FindingCandidateBatch` in
this field order:

```text
schema_version
plan_digest
unit_id
status = reviewed
findings
```

The AI cannot supply or replace those four envelope fields. Candidate payload
and stored batch are each capped at 256 KiB; all batches together are capped at
16 MiB by the later lifecycle owner. Unit-dependent same-path, contiguous
source-line, and shown-line admission is performed when the deterministic
helper records/finalizes the batch. Candidate and batch fixtures are
[`candidate.json`](../testdata/ai-review-producer-v1/protocol/candidate.json)
and [`batch.json`](../testdata/ai-review-producer-v1/protocol/batch.json).

This protocol/input slice deliberately does not assign finding IDs, resolve anchors,
construct committed-review artifacts, or publish. Those operations remain in
the ordered artifact-finalization and publication slices; partial publication
is never a protocol terminal.

## Deterministic review input

`gitframe review-input` is a first-token, no-argument helper. It reads exactly:

```text
<outer JSON header, including LF, at most 16 KiB>
<exact review-projection success frame, at most 16 MiB + 2 KiB>
<EOF>
```

The outer fields are `schema_version`, lossless absolute `repository`, the
complete expected `target`, and `projection_frame_size`. The nested frame is
independently admitted with its 2 KiB success-header cap, exact equal target,
`patch_size`, payload length, and EOF. Failure frames, unknown or duplicate
fields, mismatched targets, and short or extra bytes produce only a typed error
line. `review-input` never resolves refs or runs `git diff`.

Both fixed headers are bound to the exact compact bytes emitted by their
canonical writers, including every nested `repository` and `target` object.
Semantically equivalent field reordering, whitespace, or JSON escape aliases
are malformed input (exit 2); this strict admission does not change the
separate, existing `review-projection` request contract.

The span-preserving patch planner admits an empty patch or a sequence of
`diff --git` file records. It decodes Git C-quoted paths without requiring raw
paths to be UTF-8, validates repository-relative paths, regular-file modes,
file identity/status, complete hunk counts, UTF-8 content, CRLF and missing
final-LF markers, and accounts for every projection byte. Combined diffs,
binary/non-UTF-8 content, symlink/gitlink modes, metadata-only changes,
unknown/trailing syntax, or any incomplete count reject the complete plan.
No file or hunk can be silently omitted.

Each regular file record is one closed Git metadata state machine. Modified,
added, deleted, renamed, and copied records bind both `diff --git` paths,
`---`/`+++` markers, zero/nonzero index sides, regular mode evidence, unique
metadata and canonical order to the derived status. Added hunks consume only
the after side and deleted hunks only the before side. Missing or contradictory
evidence is malformed (exit 2); an explicitly non-regular mode remains an
unsupported projection (exit 5).

For a rename or copy with both a regular-file mode change and content hunks,
Git's canonical order is `old mode`, `new mode`, `similarity index`, identity
`from`/`to`, `index`, then the two file markers. Similarity lines admit only
their exact prefix followed by one canonical unsigned decimal from 0 through
100 and `%`; a lexically recognized dissimilarity line does not complete any
v1 metadata path and therefore fails the record. Every hunk-bearing record requires distinct
nonzero index OIDs when both sides exist, and each nonempty hunk range must end
at a representable `u32` location (`start + count - 1`) before materialization.

Lexical admission is a forward byte grammar, not whitespace normalization.
Every fixed word, ASCII space, marker, OID separator, hunk delimiter, optional
section transition, and LF is consumed at its exact position; no parser trims,
skips repeated spaces, or searches for a later closing marker. Hunk ranges use
canonical unsigned decimals: count 1 is omitted, while every other count is
explicit. A section is either absent immediately after the closing `@@`, or
starts after exactly one delimiter space and contains at least one safe byte.

Git's C-style path writer does not quote an ordinary space by itself, so the
`diff --git` header is not split at a guessed space. The planner derives the
old/new raw paths from the record's markers and rename/copy identity, rebuilds
the complete header with the one writer separator, and requires exact byte
equality. Every path spelling must also be the canonical Git encoding of its
decoded bytes. One patch-wide `core.quotePath` choice controls whether
non-ASCII bytes remain literal or use three-digit octal escapes; mixing the two
policies, unnecessary quotes, printable-byte octal aliases, and malformed
escapes are invalid.

For `---` and `+++` only, Git appends exactly one horizontal tab after a
non-`/dev/null` label iff that exact emitted path spelling contains a literal
space. The planner validates and removes only this conditional writer suffix
before decoding; a missing, extra, unconditional, or `/dev/null` tab is
invalid. No other whitespace is trimmed.

Index OID admission is bound to the already validated projection-frame
`target.object_format`. Both sides must use the same lowercase hexadecimal
width. SHA-1 admits 4 through 40 hex digits and SHA-256 admits 4 through 64
hex digits; there is no unbound/default-format parser entrypoint. Zero/nonzero
semantics remain status-specific.

Tests treat the grammar as a table-driven finite proof inventory rather than
a list of reviewer examples:

| Inventory | Complete finite dimensions |
| --- | --- |
| Lexical productions | diff header, markers, mode/index/percent/identity metadata, hunk header, three content kinds, no-final-LF marker, and every fixed delimiter mutation |
| Canonical values | both quote policies, path escape/space classes, conditional marker HT, percent/range/mode/OID spelling and exact/plus-one boundaries |
| Target OID boundary | SHA-1 and SHA-256 crossed with modified, added, deleted, renamed and copied; widths 3, 4, format maximum and maximum plus one; unequal old/new widths |
| Metadata state | modified simple/mode, added, deleted, renamed simple/mode and copied simple/mode, including deletion/duplication/reordering/substitution |
| Hunk and coverage state | exact line consumption, no-final-LF placement, adjacent ranges and one complete adjacent byte-span union |
| Actual writer controls | SHA-1/SHA-256 `core.abbrev` exact/plus-one clamping plus modify/add/delete/rename/copy/mode, both quotePath policies, path/marker/section forms |

The public boundary explicitly proves SHA-1 40/41 and SHA-256 64/65. The
named double path separator, missing hunk-close separator, missing section
separator, and target/OID mismatch regressions are ordinary cells in this
inventory. Every successful parse proves one adjacent span partition of the
complete patch, and every rejected variant produces no plan or unit.

One unit contains one file and consecutive whole hunks. Packing is in patch
order and stops at the 64 KiB raw-fragment, 9,999-location-per-side, or 19,998
line boundary; a single hunk that cannot fit is `review_unit_too_large`.
Metadata may repeat as model context, but the unit coverage spans form one
gapless, non-overlapping partition of the exact patch. Unit IDs and all
before/after location IDs are assigned only by the helper.

For each old and new file path, the helper constructs `AGENTS.md`, then each
root-to-parent `<directory>/AGENTS.md` candidate. Both labelled chains are
read only from the exact target head tree using controlled `ls-tree` and
`cat-file` calls with replace refs, lazy fetch and optional locks disabled.
The worktree, index, untracked files, filesystem file content, commands in the
documents, and any other filename are not guidance authority. Missing regular
files are normal; unavailable objects, non-regular entries, invalid UTF-8,
ambiguous output, and finite-limit overflow discard the complete plan.

The complete-plan guidance validator counts each unique `(head_oid,path)` once
across all before/after chains, caps that union at 64 and its unique exact
content at 256 KiB, and requires every repeated key to have identical blob
OID, content digest, and bytes. `instruction_set_digest` hashes ASCII
`gitframe-ai-review-instructions-v1`, one NUL, then the unique records sorted
by unsigned head-OID bytes and raw path bytes.
Each head OID, raw path, blob OID, and content field is prefixed by its unsigned
64-bit little-endian byte length; the content digest contributes its fixed 32
raw bytes between blob OID and content. `projection_digest` hashes the exact
patch bytes.

`plan_digest` hashes ASCII `gitframe-ai-review-plan-v1`, one NUL, the canonical
summary and each ordered canonical unit while every `plan_digest` field is the
all-zero SHA-256 value. The canonical component documents retain their final
LF in this preimage. The resulting digest is then inserted into the summary
and every unit. This avoids circular authority while binding the target, both
input digests, paths, guidance, locations, coverage, unit order, and complete
v1 limit set.

Success is one compact canonical JSON line with fields `schema_version`,
`status=ok`, `summary`, and ordered `units`, capped at 32 MiB. An empty patch
returns `unit_count=0` and an empty unit array; it performs no Store operation
and cannot issue a Review ID. Every failure is all-or-nothing and output-only:
exit 2 covers malformed input/arguments, exit 3 an invalid repository, exit 4
finite input/unit/line limits, exit 5 unsupported projection or guidance,
exit 6 an exact-head guidance read failure, and exit 70 an internal failure.
Every exit-4 limit error appends `resource`, `observed`, and `allowed` after
`code` and `message`. The resource token is fixed and path-free; bounded reads
stop after observing `allowed + 1`, so diagnostics never need to echo a source
or Store path or consume an unbounded payload merely to report its full size.

## Installed artifact producer

`gitframe review-producer artifacts` is the sole producer action. It reads one
bounded frame and requires EOF immediately after the declared segments:

```text
<canonical JSON header><LF>
<exact successful review-input bytes>
<candidate-0001 bytes>...<candidate-NNNN bytes><EOF>
```

The header fields are `schema_version`, `repository`,
`review_repository_id`, `review_id`, `producer`, optional `display`,
`review_input_size`, and `candidate_sizes`, in that order. `repository` is the
canonical unpadded-base64url absolute path object. There is one positive,
bounded candidate size for every ordered review unit; their aggregate is at
most 16 MiB. The header is at most 16 KiB and the review-input segment at most
32 MiB. Unknown, duplicate, missing, reordered, short, extra, or over-limit
content rejects the complete frame.

When present, `display` contains one or both non-null creation-time labels in
`base_label`, `head_label` order. The producer copies those values into the
manifest without resolving refs. An object with both values absent is not a
producer header and is omitted by the bundled Skill.

The command strictly admits the successful review-input wrapper and each
candidate payload, then re-emits and compares every nested plan summary and
unit with its canonical writer. It resolves every derived code anchor against
the exact committed target through read-only Git access. It never reads or
mutates a Review Store, publishes a Run, creates a temporary workspace, or
invokes a provider.

Success is exactly:

```text
<canonical success JSON header><LF><manifest bytes><findings bytes><EOF>
```

The success-header fields are `schema_version`, `status`,
`review_repository_id`, `review_id`, `target`, `producer`, `created_at`,
`finding_count`, `manifest_sha256`, `findings_sha256`, `manifest_size`, and
`findings_size`, in that order. The declared sizes and digests bind the exact
canonical artifact segments.

Every failure is one bounded canonical, path-free JSON line and emits no
artifact bytes. Exit 64 covers invalid arguments, frames, candidates, or
artifact input; exit 66 covers an unavailable repository or committed anchor;
exit 70 covers clock, allocation, or internal failure. The command accepts no
fallback flags, including `--help`.
