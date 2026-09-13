# AI Review Store v1

This document describes the side-effect-free read boundary, its read-only `AI Reviews` page consumer, the installed binding/publication helpers, and the Store-owned draft/result lifecycle.

## Authority

Three identities remain separate:

- `CommittedReviewTarget` is portable Git authority: object format, source kind, base OID, head OID, and diff-base OID.
- `ReviewRepositoryId` is the machine-local UUIDv4 identity issued by an explicit prepare operation. Its complete value remains authority even though only its first eight canonical characters appear in the repository directory name.
- repository and Store paths are startup/routing inputs or diagnostic data. A path never substitutes for an opened descriptor or registry binding.

Read operations re-open authority component-by-component with `O_NOFOLLOW`, validate the opened object, and use descriptor-relative children. Directory order, mtime, display labels, and a prior scan are never authority.

## Store-root resolution

The trusted config loader admits one optional key:

```toml
[ai_review]
store_root = "/absolute/canonical/path"
```

Resolution precedence is:

1. valid `[ai_review].store_root`;
2. non-empty `XDG_STATE_HOME` plus `/gitframe/ai-reviews`;
3. `HOME` plus `/.local/state/gitframe/ai-reviews`;
4. unavailable (`no_state_home`).

The resolver performs no filesystem call. It rejects `/`, relative paths, `~`, environment interpolation, NUL, empty/`.`/`..` components, repeated slash, trailing slash, and values over 4095 bytes. Invalid configured input is a fatal `invalid_ai_review_store_root`; it does not fall back. There is no Store-specific environment or invocation override.

## Read layout

```text
<store-root>/                                  0700
  registry.json                               0600, link count 1
  <repository-display-name>-<repository-id-first-8>/  0700
    .tmp-publish-<review-id>-<32 lower hex>/  0700 inert staging evidence
    .tmp-location-<review-id>-<32 lower hex>   0600, link count 1
    .tmp-draft-<review-id>-<32 lower hex>      0600, link count 1
    .tmp-result-<review-id>-<32 lower hex>     0600, link count 1
    .run-<complete-review-id>                  0600, immutable location record
    YYYYMMDD-HHMM-<target-label>-<review-id-first-8>/  0700
      manifest.json                           0600, link count 1
      findings.json                           0600, link count 1
      review_state.json                       0600, link count 1, optional
      result.json                             0600, link count 1, optional
```

Directories must be owned by the effective user, have exact mode `0700`, and remain on the Store-root device. Their POSIX link count is not an admission condition. Regular files require the same owner/device, exact mode `0600`, and link count 1.

Linux admits only an explicit local filesystem allowlist (ext family, XFS, Btrfs, F2FS, ZFS, tmpfs/ramfs, and overlayfs). macOS requires `MNT_LOCAL`, rejects read-only mounts, and rejects known FUSE type names. Remote, shared, and unknown filesystems fail closed. Cloud-sync behavior that the OS reports as an ordinary local filesystem is outside the runtime guarantee.

## Namespace staging grammar

`NamespaceTempName` is the only shared parser/formatter for publication and mutation staging. It accepts exactly one of `publish`, `location`, `draft`, or `result`, one lowercase canonical UUIDv4, and exactly 32 lowercase hexadecimal token characters.

A name becomes inert orphan evidence only after its expected file/directory metadata passes no-follow admission. Safe orphans are bounded diagnostics and never hide a canonical Run. Malformed names, unsafe objects, and all other namespace entries are non-selectable diagnostics and are never followed or cleaned by the reader. No temporary name is valid inside a canonical Run.

## Registry

`registry.json` is at most 1 MiB and 4096 bindings. Its bytes must equal the compact canonical encoding with fixed field order and a final LF. Device and inode are canonical unsigned decimal strings. Diagnostic paths are canonical absolute raw POSIX paths represented as printable UTF-8 or canonical padded RFC 4648 base64.

Each binding also requires `repository_display_name` and `directory_name`. The display name is UTF-8, contains no slash or ASCII control, is neither empty nor `.`/`..`, has no trailing `-`, and is at most 246 bytes. The directory name must be exactly `<repository_display_name>-<first 8 characters of the canonical ReviewRepositoryId>` and is at most 255 bytes.

Bindings are sorted by `(device, inode)`. A duplicate locator, duplicate `ReviewRepositoryId`, duplicate directory name, unknown/duplicate/missing field, unsupported schema, malformed path/name, unsorted entry, or noncanonical byte spelling invalidates the complete registry. Schema version remains `1`; an earlier field set is simply invalid and is not identified, read compatibly, migrated, renamed, repaired, or removed. Read-only lookup never issues an ID and never updates `last_seen_path`.

## Installed prepare helper

`gitframe review-store-prepare` is dispatched by its exact first token before global help, TUI argument parsing, terminal setup, or App startup. It accepts no arguments (`--help` is a structured `invalid_arguments` terminal) and reads at most 8 KiB of strict JSON with one optional final LF:

```json
{"schema_version":1,"repository":{"path_bytes_b64":"L2Nhbm9uaWNhbC9yZXBvc2l0b3J5"}}
```

The repository field uses the same canonical unpadded base64url/raw absolute POSIX path decoder as `review-projection`. Empty, relative, NUL-containing, padded, malformed, and over-4096-byte paths fail before Store mutation.

Prepare opens the repository and its physical Git common directory, resolves config and Store root independently of a running TUI, admits a supported local filesystem, and takes the exclusive `.locks/registry.lock`. For a new physical locator only, it runs exactly `git --no-optional-locks worktree list --porcelain -z`, requires the first record to be non-bare, and strictly admits that record's finite canonical absolute path by no-follow descriptor traversal before using its final basename. A missing, non-directory, symlink-traversing, noncanonical, or oversized main-worktree path fails before Store creation. It preserves UTF-8 bytes and case, removes only trailing `-` characters, then applies the registry display-name limits above. There is no fallback, replacement, truncation, inferred path, or retry.

Under the registry lock, prepare freshly reads the complete registry. An existing physical locator retains its full repository ID and both saved names without rerunning main-worktree discovery; only `last_seen_path` may change. A new locator receives one CSPRNG UUIDv4 binding and one exact repository directory name. Every successful request receives a fresh CSPRNG `ReviewId`:

```json
{"status":"ok","schema_version":1,"review_repository_id":"<uuid-v4>","review_id":"<uuid-v4>"}
```

Concurrent first prepare requests converge on the winner's binding. For a new binding, prepare atomically creates the exact repository directory without replacement and syncs it before registry replacement. A destination collision returns `repository_namespace_collision`; it never regenerates or extends the UUID suffix. Registry replacement uses exact canonical bytes through an exclusive owner-only temporary file, file sync, atomic replacement, Store-root sync, and lock-held strict read-back. A proven pre-commit failure removes only the operation-owned, metadata-identical empty directory. Committed, unreadable, replaced, or nonempty state is retained without repair. Existing invalid/unreadable registry authority is never treated as empty. Prepare creates no Run directory; an abandoned producer leaves the persisted empty repository namespace, binding, and unused Review ID.

## Installed immutable publication helper

`gitframe review-store-publish` has the same first-token/no-argument dispatch. Its stdin is one header of at most 16 KiB, a mandatory LF, exactly the declared raw payloads, and EOF:

```text
{"schema_version":1,"repository":{"path_bytes_b64":"<base64url>"},"review_repository_id":"<uuid-v4>","review_id":"<uuid-v4>","manifest_size":N,"findings_size":N}\n
<exact manifest.json bytes><exact findings.json bytes><EOF>
```

The manifest is capped at 256 KiB and findings at 16 MiB. Truncation, extra bytes, overflow, invalid sizes, and a second document fail before Store mutation. Publication strictly parses both artifacts, checks caller/artifact IDs, validates the manifest against the exact findings-byte digest and decoded FindingSet, and preserves both caller byte sequences without canonical rewriting.

Before taking the per-repository `publish.lock`, the helper freshly opens the repository, resolves the physical locator and active Store root, validates the registry mapping to the expected repository ID and saved actual repository directory name, and checks all three exact target OIDs as local commit objects with no fetch, replacement, or ref resolution. Under the lock it revalidates Store identity/binding and first reads only `.run-<complete-review-id>`. An exact existing Run is a duplicate; a malformed, mismatched, or incomplete location is ordinary invalid Store state. No scan, short-ID lookup, label guess, or repair is used.

Only when that location is absent, publication converts the manifest's exact UTC second once to the OS local calendar minute. A saved non-null `display.head_label` is used as-is except that each slash run becomes one `-` and component-edge hyphens are removed. It must then be valid UTF-8, contain no ASCII control, be nonempty and neither `.` nor `..`, and fit 232 bytes. A present-invalid label fails without fallback. Only an absent head label uses `commit-<first 7 head-OID hex>`. The final stored component is `YYYYMMDD-HHMM-<target-label>-<first 8 review-ID hex>` and is never recomputed after publication.

Publication writes one `.tmp-publish-...` directory containing the exact immutable artifacts and one same-token `.tmp-location-...` regular file containing strict canonical schema-1 JSON: full repository ID, full review ID, and the actual directory component. After both are synced, it atomically installs `.run-<complete-review-id>` without replacement, syncs the namespace, then atomically installs the Run directory under its readable name and syncs again. A final-name collision returns `run_name_collision`; it never regenerates the UUID, retries, extends the suffix, or chooses another name. Before the Run rename, cleanup may remove only the operation-owned byte- and metadata-identical locator and staging entries. Once the Run rename commits, both entries are retained; a following durability error is reconciled by the full-ID locator and exact artifact bytes, without republishing.

Both helpers emit one canonical JSON terminal plus LF/EOF. Repository preparation preserves `main_worktree_unavailable`, `repository_name_invalid`, and `repository_namespace_collision`; publication preserves `target_label_invalid`, `local_time_unavailable`, and `run_name_collision`. Hosted Compare jobs carry the same bounded causes through the existing footer and F2 details. Exit groups are: `0` success; `64` request/schema/artifact errors; `65` invalid repository or target label; `66` unavailable target objects; `69` unavailable/unsupported Store platform or filesystem; `73` duplicate review ID or repository/Run name collision; `74` invalid Store/repository, unavailable main worktree/local time, Git, or I/O failure; `75` binding/concurrent conflict; and `70` allocation or unclassified internal failure. Stderr text, raw names, and Store paths are never machine authority.

## Run admission and result precedence

A stored Run directory must contain required `manifest.json` and `findings.json`, plus at most optional `review_state.json` and `result.json`. Its manifest full IDs, strict `.run-<complete-review-id>` record, saved actual directory name, and repository binding must agree. Any other Run-internal entry invalidates that Run.

Immutable artifacts are strictly parsed and cross-validated for directory/manifest IDs, repository namespace, schema, target, producer, `created_at`, finding count, and the digest of every exact `findings.json` byte. Zero findings and optional producer timing are valid.

If `result.json` exists, it must be valid; an invalid result never falls back to a draft. A valid result is self-contained terminal authority and makes the Run `completed`. A missing, unsafe, malformed, or nonmatching retained draft becomes only a bounded `retained_draft_invalid` diagnostic and cannot hide or downgrade that completed Run. Without a result, a present draft must be valid with a positive revision; otherwise the Run is invalid. Result/draft snapshot equality belongs to later result creation under the per-Run lock, not read admission.

## History transaction

An explicit scan performs:

1. fresh physical Git common-directory locator discovery;
2. read-only Store-root open;
3. strict registry lookup without get-or-create;
4. repository namespace open;
5. complete bounded enumeration of readable-name candidates and full-ID location records, followed by their strict pairwise admission;
6. one bounded Git availability batch for all valid targets;
7. full deterministic sort.

Missing Store/registry/binding is unbound. A present binding with a missing or invalid saved namespace is ordinary invalid Store state; it is never recreated or renamed. An existing empty saved namespace is bound-empty. Invalid-only history is distinct: it returns zero rows with bounded skipped diagnostics.

Every namespace entry counts toward 1024 entries and 256 KiB of names. At most 512 canonical Run candidates and 256 MiB of aggregate artifact bytes are admitted. Limit overflow discards all partial rows; no filesystem prefix is presented as history. At most eight sanitized single-line diagnostics of 256 display bytes are retained.

Rows own display-safe copies only. Sort authority is validated manifest `created_at` descending, then canonical review ID ascending. The timestamp uses the same strict UTC-second parser/conversion seam as the artifact codec.

## Git availability and selection

Availability validates at most 512 targets against the repository object format, then sends exactly three full OIDs per target to one controlled command:

```text
git --no-replace-objects --no-lazy-fetch --no-optional-locks \
  cat-file --batch-check=%(objectname) %(objecttype)
```

Only an ordered `<oid> commit` or `<oid> missing` record is accepted. Wrong count/order/OID/type, overflow, object-format drift, nonzero/signal, or process failure discards the whole batch. It never fetches, resolves a ref, consults replacements, or mutates checkout/index.

Selection treats scan rows as provisional. It owns a duplicated repository capability, controlled environment, Store-root path, fresh Store descriptor, parsed artifacts, and projection bytes. Before returning it revalidates physical repository locator, Store root device/inode, registry binding, namespace, exact Run artifacts, and object availability, then materializes the existing checkout-independent exact committed projection once. Any drift or missing object returns a typed failure without substituting a scan snapshot, current ref, or similar revision.

## AI Reviews page Run picker

On the `AI Reviews` page, `a` opens the keyboard-only Run picker and starts one fresh asynchronous scan. The initial page is unselected and shows `a: select AI review`; GitFrame does not scan at startup and does not create a missing Store, registry, binding, namespace, or Run. There is no synthetic normal-comparison row. Valid Run rows remain newest-first and show their artifact-derived `new`, `draft`, `approved`, `needs changes`, or `canceled` status. Missing Git objects are shown independently as `target unavailable`.

Use `/` to filter, `j`/`k` or arrow keys to move, Enter to activate, `r` to refresh or retry, and Esc/`q` to close. Query mode accepts printable command letters; Esc clears a non-empty query, then returns to command mode, and a further Esc closes. Invalid-only and unavailable states remain typed, bounded, and retryable.

Selecting a Run revalidates the exact IDs and artifacts before replacing the visible diff atomically. A failed or stale selection leaves the previous selected Run intact. On the `AI Reviews` page, `r` reloads that exact Run and `m` is unowned; branch comparison and `m` base selection belong only to the separate `Compare` page. Switching to another page and back retains the selected Run and its navigation without reopening the picker, while repository replacement clears the old repository's selection. Bare Esc outside the picker does not clear the selected Run.

## Draft and result persistence

Mutation requests contain an exact repository ID, review ID, committed target,
and findings digest; callers never select a draft/result pathname. Draft input
is one complete snapshot: expected revision (`0` means absent), optional
summary, every finding disposition, and every anchored note. Existing notes are
therefore retained only when the caller includes them in the next snapshot.

Under the per-Run lock, the writer freshly validates registry binding, opens
the binding's saved actual repository directory, directly resolves the full
review ID through its unchanged location record, and validates the saved actual
Run directory. A valid result returns `already_completed` before draft
inspection, including when a retained draft is missing or invalid. Without a
result, the actual draft revision must exactly equal the request. GitFrame
assigns revision `1` or the checked next revision, validates the constructed
artifact, and never auto-merges or overwrites a conflicting snapshot.

Draft bytes are exclusively created as one shared-grammar
`.tmp-draft-<review-id>-<token>` namespace sibling with mode `0600`. The write
order is complete bytes, file sync, namespace sync, atomic replacement rename
to the saved actual Run's `review_state.json`, Run-directory sync, then namespace sync.
Before-rename failure leaves the old draft authoritative; post-rename sync
failure may leave the new complete draft authoritative. Retry always reopens
the Run instead of rolling back.

A result request carries only the expected latest draft revision and decision.
After reloading that draft, GitFrame samples the real clock exactly once,
formats one UTC-second RFC 3339 `completed_at`, and copies the exact latest
summary, dispositions, and notes into the terminal result. Result staging uses
the corresponding `.tmp-result-...` file and sync order, followed by an atomic
no-replace rename. A concurrent winner is reloaded under the same lock: a valid
winner returns `already_completed`, an invalid winner returns `run_invalid`,
and existing bytes are never replaced.

Normal pre-rename cleanup removes only the exact temporary file created by the
operation and syncs the namespace after successful removal. Cleanup failure or
external termination may leave that safe inert sibling; it cannot hide a
canonical Run. Filesystem terminals are `conflict`, `draft_required`,
`already_completed`, `binding_changed`, `run_invalid`, `clock_unavailable`,
`unsupported`, and `io_failed`.

## App operation ownership and quit

`ReviewStoreOperationOwner` is independent of Git action lifecycle. It keys
work by repository ID plus review ID, runs at most one filesystem task per Run,
and permits different Runs to execute independently. The bounded owner admits
at most 64 active Runs, with one in-flight operation, one pending draft, and one
pending result per Run. A compatible newer unstarted draft replaces the prior
pending draft; in-flight input is immutable. A result waits behind the accepted
draft revision and is never coalesced.

Task completion is matched by operation ID and full Run binding, not the
current page. The App clones request bytes before admission, so conflict,
failure, page switch, and repository switch cannot discard or mutate the
caller's dirty editor state. A matching selected AI Review Run receives its bounded
completion notification; every mismatched, stale, or runtime-undelivered
payload is still deinitialized exactly once.

If an in-flight mutation fails, every accepted dependent draft or result is
retired with the same typed terminal and its operation ID remains observable;
the owner never retains an unstartable blocked queue. After those clones are
released, the Run admits a fresh explicit retry or reconciliation request.

Quit closes new Store-mutation admission and invalidates outstanding Store read
generations. With no accepted mutation it follows normal teardown. Otherwise
the TUI remains responsive while all accepted per-Run queues drain. Complete
success returns to the existing quit coordinator, which rechecks any Git action
admitted during the responsive drain before teardown. Any Store failure cancels
quit, reopens admission, reports the typed terminal, and leaves caller-owned
dirty state available for explicit reload/reconciliation.

## Starting a hosted review from Compare

The `Compare` page can submit its currently accepted committed branch range to
the Codex CLI. Configure an absolute executable path; the model is optional:

```toml
[ai_review]
codex_executable = "/absolute/path/to/codex"
codex_model = "optional-runner-model"

# Common execution limits; all four may be omitted.
max_input_bytes = 1048576
max_final_output_bytes = 262144
max_stream_output_bytes = 8388608
timeout_seconds = 1800
```

GitFrame uses the CLI's existing authentication context and does not select,
inspect, or store whether that context uses a subscription or API billing. If
`codex_model` is absent, the runner default is used.

Press `a` on `Compare` to inspect the exact base and head OIDs, optionally enter
up to 16 KiB of review context, and press Enter to start. Submission revalidates
the accepted repository and target; a configuration, stale-target, or queue
failure remains in the modal without starting work. An accepted job runs in the
background and appears in the existing one-line footer as `queued`, `reviewing`,
`publishing`, or a terminal outcome. Esc dismisses only the currently visible
unread terminal. Selecting the exact published Run on `AI Reviews` acknowledges
that job without affecting another Run.

The hosted path publishes through the same Store domain as external producers,
but it does not invoke the installed `gitframe-ai-review` Skill or `review.py`.
Runs created externally remain available on `AI Reviews`; they do not have an
in-memory GitFrame job status.

### Common execution limits

These are provider-neutral limits under `[ai_review]`, not Codex/model overrides.
Missing files, omitted keys, partial settings, and the existing Store/executable/model
settings retain their defaults. Values are decimal integers; startup rejects
non-integers, negative/zero values, overflow, duplicate keys, and unsupported
combinations with the key and reason. There is no zero/unlimited value.

| Key | Default | Meaning and supported range |
| --- | --- | --- |
| `max_input_bytes` | 1048576 (1 MiB) | Entire generated prompt: instruction, context, serialized Review Units, and JSON escaping. `1..maxInt(usize)/2`. |
| `max_final_output_bytes` | 262144 (256 KiB) | Decoded final answer for one complete provider call, including its multi-unit envelope. `1..262144`. |
| `max_stream_output_bytes` | 8388608 (8 MiB) | All stdout wire bytes, including intermediate JSONL events and escaping. `1..maxInt(usize)/2`, and at least `max_final_output_bytes`. |
| `timeout_seconds` | 1800 (30 minutes) | Shared execution budget, `1..4294967295` seconds. |

Exactly the configured byte limit is accepted; exceeding it fails the whole
operation. No truncated prompt or partial answer becomes a successful review.
The machine-sized byte ceiling leaves room for bounded-reader arithmetic and
the `N+1` overflow observation. It does not reserve that much memory.
`stream >= final` does not guarantee that JSONL overhead/escaping will fit.

Configuration is loaded at startup; each accepted Compare request copies all
four values. Queued/running requests and retained diagnostics keep that snapshot.
Changes require a restart and affect only new requests; there is no hot reload.
The timeout starts immediately before the version probe and uses the same
absolute deadline through the main provider process. Queue wait, Git/input
preparation, prompt/private-environment creation, answer decoding/validation,
and Store publication are excluded. An earlier caller deadline still wins.
The probe also retains its separate, non-terminal 5-second local cap.

These limits do not replace provider/model service limits or protocol/Store
validation. Context remains 16 KiB, stderr remains 64 KiB, per-unit candidate
payloads remain 256 KiB, and the candidate aggregate remains 16 MiB. The 256 KiB
whole-answer ceiling is a separate GitFrame runtime/product limit, not a claim
that the per-unit protocol ceiling applies to a multi-unit answer.

Existing F2 details show the failed job's allowed/observed bytes or timeout
budget and point to the applicable common key. Protocol/context/stderr limits
and caller-owned deadlines do not suggest an unrelated setting. Raising an
input setting does not guarantee acceptance by a model or provider.

## Resource ownership and current non-goals

Every success/failure/skip terminal frees parsed arenas, raw artifact bytes, diagnostics, projection buffers, environments, and descriptors exactly once. The focused suite covers success and drift/failure union terminals with `std.testing.allocator`.

Config resolution, scan, selection, picker use, exact selected-Run refresh, and page navigation create no Store content. Only the two installed explicit producer helpers create bindings or immutable Run pairs; only the mutation owner writes GitFrame-owned draft/result artifacts. No disposition, anchored-note, or terminal-decision UI is introduced by this storage slice. Those consumer surfaces remain follow-up responsibilities.
