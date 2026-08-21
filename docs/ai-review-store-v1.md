# AI Review Store v1

This document describes the side-effect-free read boundary, its read-only `Review` page consumer, and the installed binding/publication helpers. Draft/result mutation remains a separate responsibility.

## Authority

Three identities remain separate:

- `CommittedReviewTarget` is portable Git authority: object format, source kind, base OID, head OID, and diff-base OID.
- `ReviewRepositoryId` is a machine-local UUIDv4 Store namespace issued by a later explicit prepare operation.
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
  <review-repository-id>/                     0700
    .tmp-publish-<review-id>-<32 lower hex>/  0700 inert staging evidence
    .tmp-draft-<review-id>-<32 lower hex>      0600, link count 1
    .tmp-result-<review-id>-<32 lower hex>     0600, link count 1
    <review-id>/                              0700
      manifest.json                           0600, link count 1
      findings.json                           0600, link count 1
      review_state.json                       0600, link count 1, optional
      result.json                             0600, link count 1, optional
```

Directories must be owned by the effective user, have exact mode `0700`, and remain on the Store-root device. Their POSIX link count is not an admission condition. Regular files require the same owner/device, exact mode `0600`, and link count 1.

Linux admits only an explicit local filesystem allowlist (ext family, XFS, Btrfs, F2FS, ZFS, tmpfs/ramfs, and overlayfs). macOS requires `MNT_LOCAL`, rejects read-only mounts, and rejects known FUSE type names. Remote, shared, and unknown filesystems fail closed. Cloud-sync behavior that the OS reports as an ordinary local filesystem is outside the runtime guarantee.

## Namespace staging grammar

`NamespaceTempName` is the only shared parser/formatter for future publication and mutation staging. It accepts exactly one of `publish`, `draft`, or `result`, one lowercase canonical UUIDv4, and exactly 32 lowercase hexadecimal token characters.

A name becomes inert orphan evidence only after its expected file/directory metadata passes no-follow admission. Safe orphans are bounded diagnostics and never hide a canonical Run. Malformed names, unsafe objects, and all other namespace entries are non-selectable diagnostics and are never followed or cleaned by the reader. No temporary name is valid inside a canonical Run.

## Registry

`registry.json` is at most 1 MiB and 4096 bindings. Its bytes must equal the compact canonical encoding with fixed field order and a final LF. Device and inode are canonical unsigned decimal strings. Diagnostic paths are canonical absolute raw POSIX paths represented as printable UTF-8 or canonical padded RFC 4648 base64.

Bindings are sorted by `(device, inode)`. A duplicate locator, duplicate `ReviewRepositoryId`, unknown/duplicate field, unsupported schema, malformed path, unsorted entry, or noncanonical byte spelling invalidates the complete registry. Read-only lookup never issues an ID and never updates `last_seen_path`.

## Installed prepare helper

`gitframe review-store-prepare` is dispatched by its exact first token before global help, TUI argument parsing, terminal setup, or App startup. It accepts no arguments (`--help` is a structured `invalid_arguments` terminal) and reads at most 8 KiB of strict JSON with one optional final LF:

```json
{"schema_version":1,"repository":{"path_bytes_b64":"L2Nhbm9uaWNhbC9yZXBvc2l0b3J5"}}
```

The repository field uses the same canonical unpadded base64url/raw absolute POSIX path decoder as `review-projection`. Empty, relative, NUL-containing, padded, malformed, and over-4096-byte paths fail before Store mutation.

Prepare opens the repository and its physical Git common directory, resolves config and Store root independently of a running TUI, admits a supported local filesystem, and takes the exclusive `.locks/registry.lock`. Under that lock it freshly reads the complete registry. An existing physical locator retains its repository ID and may update only `last_seen_path`; a new locator receives one CSPRNG UUIDv4 binding. Every successful request receives a fresh CSPRNG `ReviewId`:

```json
{"status":"ok","schema_version":1,"review_repository_id":"<uuid-v4>","review_id":"<uuid-v4>"}
```

Concurrent first prepare requests converge on the winner's binding. Registry replacement is exact canonical bytes through an exclusive owner-only temporary file, file sync, atomic replacement, and Store-root sync. Existing invalid/unreadable registry authority is never treated as empty. Prepare creates no repository namespace or Run directory; an abandoned producer leaves only its binding and unused Review ID.

## Installed immutable publication helper

`gitframe review-store-publish` has the same first-token/no-argument dispatch. Its stdin is one header of at most 16 KiB, a mandatory LF, exactly the declared raw payloads, and EOF:

```text
{"schema_version":1,"repository":{"path_bytes_b64":"<base64url>"},"review_repository_id":"<uuid-v4>","review_id":"<uuid-v4>","manifest_size":N,"findings_size":N}\n
<exact manifest.json bytes><exact findings.json bytes><EOF>
```

The manifest is capped at 256 KiB and findings at 16 MiB. Truncation, extra bytes, overflow, invalid sizes, and a second document fail before Store mutation. Publication strictly parses both artifacts, checks caller/artifact IDs, validates the manifest against the exact findings-byte digest and decoded FindingSet, and preserves both caller byte sequences without canonical rewriting.

Before taking the per-repository `publish.lock`, the helper freshly opens the repository, resolves the physical locator and active Store root, validates the registry mapping to the expected repository ID, and checks all three exact target OIDs as local commit objects with no fetch, replacement, or ref resolution. Under the lock it revalidates Store identity/binding and rejects any existing final review name without comparing or replacing content.

Publication writes only one `.tmp-publish-<review-id>-<128-bit-lower-hex>` owner-only directory in the bound namespace. It exclusively creates and syncs exact `manifest.json` and `findings.json`, syncs the staging directory and namespace, atomically renames without replacement to `<review-id>`, and syncs the namespace again. Before rename, every failure exposes no canonical Run. Cleanup unlinks only the two expected files and then the exact operation-owned empty staging directory; it never recursively deletes or touches another temporary/final entry. A failure after the no-replace rename may leave the complete byte-valid Run visible and a retry returns `duplicate_review_id`.

Both helpers emit one canonical JSON terminal plus LF/EOF. Exit groups are: `0` success; `64` request/schema/artifact errors; `66` unavailable target objects; `69` unavailable/unsupported Store platform or filesystem; `73` duplicate review ID; `74` invalid Store/repository, Git, or I/O failure; `75` binding/concurrent conflict; and `70` allocation or unclassified internal failure. Stderr text and Store paths are never machine authority.

## Run admission and result precedence

A canonical Run directory must contain required `manifest.json` and `findings.json`, plus at most optional `review_state.json` and `result.json`. Any other Run-internal entry invalidates that Run.

Immutable artifacts are strictly parsed and cross-validated for directory/manifest IDs, repository namespace, schema, target, producer, `created_at`, finding count, and the digest of every exact `findings.json` byte. Zero findings and optional producer timing are valid.

If `result.json` exists, it must be valid; an invalid result never falls back to a draft. A valid result is self-contained terminal authority and makes the Run `completed`. A missing, unsafe, malformed, or nonmatching retained draft becomes only a bounded `retained_draft_invalid` diagnostic and cannot hide or downgrade that completed Run. Without a result, a present draft must be valid with a positive revision; otherwise the Run is invalid. Result/draft snapshot equality belongs to later result creation under the per-Run lock, not read admission.

## History transaction

An explicit scan performs:

1. fresh physical Git common-directory locator discovery;
2. read-only Store-root open;
3. strict registry lookup without get-or-create;
4. repository namespace open;
5. complete bounded enumeration and per-Run admission;
6. one bounded Git availability batch for all valid targets;
7. full deterministic sort.

Missing Store/registry/binding is unbound. A missing bound namespace is bound-empty. Invalid-only history is distinct: it returns zero rows with bounded skipped diagnostics.

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

## Review page history picker

On the `Review` page, `a` opens the keyboard-only `Reviews` picker and starts one fresh asynchronous scan. GitFrame does not scan at startup and does not create a missing Store, registry, binding, namespace, or Run. The fixed `Normal Review` row is always first and is never filtered; valid Run rows remain newest-first and show their artifact-derived `new`, `draft`, `approved`, `needs changes`, or `canceled` status. Missing Git objects are shown independently as `target unavailable`.

Use `/` to filter, `j`/`k` or arrow keys to move, Enter to activate, `r` to refresh or retry, and Esc/`q` to close. Query mode accepts printable command letters; Esc clears a non-empty query, then returns to command mode, and a further Esc closes. Invalid-only and unavailable states remain typed, bounded, and retryable.

Selecting a Run revalidates the exact IDs and artifacts before replacing the visible diff atomically. A failed or stale selection leaves the previous normal or pinned presentation intact. In pinned mode, `r` reloads the exact Run and `m` returns through a fresh normal branch-comparison load; it never retargets the pinned OIDs through the base picker. Bare Esc outside the picker does not leave pinned mode.

## Resource ownership and current non-goals

Every success/failure/skip terminal frees parsed arenas, raw artifact bytes, diagnostics, projection buffers, environments, and descriptors exactly once. The focused suite covers success and drift/failure union terminals with `std.testing.allocator`.

Config resolution, scan, selection, picker use, pinned refresh, and return-to-normal create no Store content. The App owns only ephemeral task results, picker snapshots, and the currently accepted normal or pinned presentation. Only the two installed explicit producer helpers create bindings or immutable Run pairs. No draft/result writer, mutation UI, or App-level Store mutation owner is exported; those responsibilities belong to the later `review-state-persistence` slice.
