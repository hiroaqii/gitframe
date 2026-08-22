# AI review producer protocol v1

This document defines the provider-neutral protocol foundation used by the
portable `gitframe-ai-review` Skill. The foundation does not invoke an AI,
materialize a projection, mutate the Review Store, publish a Run, install a
Skill, or read a human result.

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

The fixture directory
[`testdata/ai-review-producer-v1/protocol`](../testdata/ai-review-producer-v1/protocol)
contains exact canonical documents.

## Capability handshake

`gitframe review-capabilities` takes no arguments, does not read stdin, and
does not open a repository, config, Store, TUI, or installation state. Success
is one `CapabilityResponse`:

```json
{"schema_version":1,"status":"ok","gitframe_version":"0.0.0","capabilities":[{"name":"committed-review.artifact","versions":[1]}]}
```

Capability names are strictly increasing by unsigned UTF-8 bytes. Each
versions array is non-empty, positive, strictly increasing, and unique.
Compatibility is exact name/version membership; GitFrame semver is diagnostic
only and a future-only `[2]` does not satisfy a v1 requirement.

The protocol-foundation release advertises exactly, in order:

1. `committed-review.artifact@1`
2. `committed-review.projection@1`
3. `committed-review.target@1`
4. `review-store.prepare@1`
5. `review-store.publish@1`

No `ai-review.*`, `committed-review.instructions`, `review-store.verify`, or
installation capability is advertised before its owning later slice exists
and passes its contract tests.

Any argument, including `--help`, returns exit 2 and a bounded canonical error
line. Allocation/internal failure returns exit 70. Successful output is capped
at 16 KiB.

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
across the complete plan. The later input materializer owns that global union,
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
does not claim the complete-plan limit owned by the later materializer. The
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

This foundation deliberately does not assign finding IDs, resolve anchors,
construct committed-review artifacts, or publish. Those operations remain in
the ordered artifact-finalization and publication slices; partial publication
is never a protocol terminal.
