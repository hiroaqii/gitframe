# Candidate and lifecycle protocol

The driver requires GitFrame v1 capabilities for target, projection,
instructions, input, producer artifacts, Store prepare and Store publish.
There is no provider SDK or shell interpolation. All child invocations use the
one absolute GitFrame executable admitted by `begin`.

## Candidate document

Write compact UTF-8 JSON plus one LF. The top-level fields are ordered as
shown:

```json
{"findings":[]}
```

Each finding follows the candidate shape documented by the installed GitFrame
producer protocol: `start_location`, `end_location`, severity, title, body and
optional suggestion. Draw both opaque location IDs only from the matching
unit. Do not add `schema_version`, `unit_id` or plan fields: the deterministic
producer owns that envelope. Do not invent target OIDs, raw paths, line
ranges, finding IDs, anchors, artifact fields or Review IDs. A candidate is
positive length and at most 256 KiB; all candidates together remain within
GitFrame's 16 MiB producer limit.

Before completing, verify the filename ordinal matches the unit ordinal,
there is exactly one candidate per issued unit, the file is a regular
owner-owned non-symlink with mode `0600`, and the JSON has no comments,
duplicate fields, trailing whitespace or extra documents. GitFrame performs
the final strict and semantic validation.

## Lifecycle boundaries

`begin` first checks all required capabilities, then resolves a target,
materializes its committed projection, and constructs deterministic units. An
empty plan returns `no_changes` before Store prepare. A non-empty plan calls
prepare once, receives fresh identifiers, and creates one private `0700`
workspace beneath the platform temporary root. The raw 256-bit nonce appears
only in the `ready` handoff; `invocation.json` stores its SHA-256 digest.

`complete` admits the exact direct-child workspace, ownership/mode, nonce,
saved input hashes and candidate inventory. Pre-publication failures do not
call publish. Valid input calls `review-producer artifacts` once, verifies the
entire binary frame and calls `review-store-publish` at most once. There is no
automatic retry. Duplicate or concurrent use of one complete handoff is not a
supported operation; GitFrame's create-once Store remains the final
no-replacement guard.

Timeouts are 10 seconds for capabilities and 120 seconds for each remaining
helper. Stdout, stderr and every stored payload have fixed bounds. A publish
timeout, signal, overflow, empty output or malformed terminal after child
start yields `outcome_unknown`, because the immutable rename might already
have happened.

## Resolving an unknown outcome

Do not begin by retrying publication. Copy `repository`, `review_id` and the
complete `expected` object from the `outcome_unknown` result into this strict
request without re-encoding any field:

```text
{"schema_version":1,"repository":{"path_bytes_b64":"<canonical-padded-standard-base64>"},"review_id":"<uuid-v4>","expected":<expected-object>}
```

The returned `repository.path_bytes_b64` is the existing read command's
canonical RFC 4648 standard Base64 form, including required `=` padding. It is
deliberately distinct from the unpadded URL-safe repository wire used by the
producer, input and publish commands. Never substitute or normalize one form
for the other.

Pipe that one compact document plus LF to:

```text
<absolute-gitframe> review-store-read
```

An `ok` terminal with matching identity and `lifecycle":"published"` confirms
success. A typed absent/unbound response confirms only the state observed by
that read; preserve the original unknown terminal and investigate before any
new `begin`. A new supported attempt always starts with a new `begin`, new
Review ID and new workspace.
