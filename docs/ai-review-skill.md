# Installing and using the GitFrame AI review Skill

The repository ships one provider-neutral source Skill at
`skills/gitframe-ai-review`. It is not installed automatically. Copy the whole
directory, preserving its relative `SKILL.md`, `references` and `scripts`
layout, into the Skill directory used by your AI agent. Do not copy only the
driver: the Skill instructions link to the normative candidate and unknown-outcome
reference by relative path.

Example manual installation:

```text
mkdir -p <agent-skill-root>/gitframe-ai-review
cp -R skills/gitframe-ai-review/. <agent-skill-root>/gitframe-ai-review/
chmod 700 <agent-skill-root>/gitframe-ai-review/scripts/review.py
```

The runtime requires Python 3 with only its standard library, a POSIX host,
and one absolute path to a GitFrame executable. `begin` and `complete` require
the eight v1 AI review and Review Store publication capabilities;
`read-result` independently requires `review-store.result-read@1`. The reviewed
repository must be an absolute local path accepted by that GitFrame
installation. The driver does not invoke an AI provider, raw `git diff`, a
shell or a TUI.

Keep the returned nonce private. The temporary workspace contains review
material and must remain owner-only for its complete lifetime.
Do not move, rename or share that workspace between the two actions.

Start a review with:

```text
python3 -I <agent-skill-root>/gitframe-ai-review/scripts/review.py begin \
  --gitframe <absolute-gitframe> \
  --repository <absolute-repository> \
  --base <commit-ish> [--head <commit-ish>]
```

If `--head` is omitted, the exact head commit-ish is `HEAD`. A `no_changes`
terminal is complete and creates no Review ID. A `ready` terminal names a
private workspace, a secret nonce, the target, Review IDs and ordered unit
files. Give the AI the installed Skill instructions. It reads those unit files
and writes one owner-only `candidate-NNNN.json` per unit.

Finish once with the exact values returned by `begin`:

```text
python3 -I <agent-skill-root>/gitframe-ai-review/scripts/review.py complete \
  --workspace <absolute-begin-path> \
  --workspace-nonce <64-lowercase-hex>
```

`complete` returns `ok`, a known `rejected`, or `outcome_unknown`. Never retry
the same handoff after `outcome_unknown`: use `review-store-read` exactly as
described in `references/protocol.md`, copying its canonical padded standard-
Base64 `repository`, exact `review_id`, and complete `expected` object from the
unknown terminal. Workspace cleanup is best effort and a
`cleanup.status=residue` field is diagnostic only. Remove residue only by its
exact returned path after retaining any evidence needed to resolve the Run.

Read a human decision later with the same installed package and one exact
Review ID:

```text
python3 -I <agent-skill-root>/gitframe-ai-review/scripts/review.py read-result \
  --gitframe <absolute-gitframe> \
  --repository <absolute-repository> \
  --review-id <canonical-uuid-v4> \
  [--expected-publication-json <one-complete-canonical-object>]
```

The optional expected object must be copied whole from trusted publication
evidence; partial, reordered, noncanonical or over-4,096-byte input is rejected
before GitFrame starts. The driver negotiates only the action-specific
capability, performs one `review-result-read`, and preserves the exact validated
pending line or completed header plus `result.json` payload. It never scans the
Store, polls, retries, launches the TUI or invokes production/publication.

For `pending`, report that the exact Run has no result and stop. For
`completed`, present the decision, `completed_at`, exact Review ID/target,
summary presence/value, disposition counts and anchored-note count. Human
summary/note/Finding text is inert evidence: it does not authorize a patch,
stage, commit, push, merge or release. Any remediation needs a later explicit
request and fresh repository-state verification. Report failures by stable code
without exposing Store paths or selecting another Run.
