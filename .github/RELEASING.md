# GitHub Releases

The Release workflow builds with Zig 0.16.0 and `ReleaseSafe`:

| Asset platform | Build and test runner | Zig target | CPU |
| --- | --- | --- | --- |
| `linux-x86_64` | `ubuntu-22.04` | `x86_64-linux.5.15-gnu.2.35` | `baseline` |
| `macos-arm64` | `macos-15` | `aarch64-macos.15.0` | `baseline` |

Linux requires kernel 5.15+ and glibc 2.35+. macOS requires macOS 15+ on Apple
Silicon. Both require Git 2.45.1 or newer on `PATH` at runtime. The macOS binary
is not Developer ID signed or notarized; browser downloads can require a
Gatekeeper override.

## Prepare the version and release notes

First write the release body in `.github/release-notes/vMAJOR.MINOR.PATCH.md`
for the version you want to release. The preparation script requires this file
to exist and contain non-whitespace text; it does not generate release notes.

From the repository root, run:

```sh
# Replace MAJOR.MINOR.PATCH with the new stable version, without a v prefix.
python3 scripts/prepare-release.py MAJOR.MINOR.PATCH --dry-run
python3 scripts/prepare-release.py MAJOR.MINOR.PATCH
```

This requires Python 3.10 or newer, Git with a commit name/email configured,
and GitHub CLI authenticated with `gh auth login` to check remote tags. The
script verifies the version and notes, checks that the tag does not already
exist locally or on GitHub, updates `build.zig.zon`, and commits only that file
and the matching release notes. It creates no tag and performs no push.

The new version must be numerically greater than the version in `build.zig.zon`.
Equal or older versions and prereleases are rejected. For example, patch `10`
is newer than patch `9`. Missing/blank notes, an existing tag, or a failed remote
tag lookup stop the command before file edits or a commit. `--dry-run` performs
the same validation and shows the version diff without modifying files or Git
state.

The script must run on a branch outside an in-progress merge/rebase/cherry-pick.
`build.zig.zon` must match HEAD in both the working tree and index, so unrelated
manifest edits cannot enter the preparation commit. Other staged, unstaged, and
untracked files are preserved and excluded from the commit. The preparation
script itself can remain local and uncommitted. If Git rejects the commit
(for example, a hook fails), inspect the version/notes edits and finish the
commit manually; the script leaves them available rather than resetting files.

Review the resulting commit, then push the branch before running
`scripts/release-github.py`. On `main`:

```sh
git show HEAD
git push origin main
```

If dependency updates are part of the release, commit and validate those changes
before using `prepare-release.py`; its clean-manifest check prevents bundling
unrelated manifest edits into the automatic version commit.

You can also prepare manually: update the version and dependencies in
`build.zig.zon`, write the matching notes, then commit and push the reviewed
changes before creating the tag or running Release. Once the version is already
updated, skip `prepare-release.py` and use `release-github.py` after the push.

Run the commands below from the repository root. The orchestration script reads
the version from `build.zig.zon` at HEAD; the manual commands use the working-tree
version via `scripts/release.py version`.

The Markdown file is used as the complete release body. No generated changelog
is appended. A missing, empty, or whitespace-only file stops the workflow
before building, and the publish script checks it again before accessing
GitHub. The notes are read from the same commit as the release tag.

## Release from a pushed commit

Use Python 3.10 or newer, Git, and an authenticated GitHub CLI (`gh auth login`)
with permission to run Actions and push tags in `hiroaqii/gitframe`. Commit and
push the changes you want to release, including the version and release notes,
first. Local HEAD must match the remote `main` branch when creating a new release.

The orchestration script itself can remain local and uncommitted. Uncommitted,
staged, and untracked files do not block execution and are not included in the
release. The version and release notes are read directly from the selected HEAD
commit, not from your working tree or index. Actions uses the workflow and build
scripts from that commit, so local workflow edits do not affect this release.

```sh
# Inspect the target version, commit, and existing release without publishing.
python3 scripts/release-github.py --dry-run

# Push the version tag, then wait for Linux/macOS validation and publication.
python3 scripts/release-github.py
```

The version comes from `build.zig.zon` at HEAD; no version argument is needed. The
script creates an annotated tag at that exact commit and pushes only that tag.
The tag-triggered **Release** workflow builds and tests both platforms, then
publishes only after both succeed. Normal execution uses one workflow run.
The script then verifies both archives and `SHA256SUMS` against the SHA-256
digests reported by GitHub for the uploaded assets.
It never pushes the source branch or rewrites an existing tag or published release.

To also validate before creating the tag, explicitly request a preflight:

```sh
python3 scripts/release-github.py --preflight
```

This starts or reuses a validation run for the selected commit before pushing
the tag. The tag-triggered workflow then builds and tests again, so this option
uses two workflow runs. It is optional, including when releasing from a local,
uncommitted orchestration script. A failed preflight stops before tag creation.

Run the same command again after interruption. It reuses the existing tag or
published release; an existing tag also skips preflight even when requested.
A tag pointing to another commit stops the command. If local HEAD or the remote
branch changes before tagging, no tag is pushed. Editing uncommitted files does
not change the selected release commit. Build or test failures in the tag's run
leave the tag in place and prevent publication. To rerun a failed workflow, use
`python3 scripts/release-github.py --retry-failed`. All jobs in that failed
workflow are rerun. To retry a failed optional preflight before tagging, keep
both flags: `python3 scripts/release-github.py --preflight --retry-failed`.
`--timeout SECONDS` changes the one-hour wait limit per
workflow; timing out or pressing Ctrl-C does not cancel Actions.

`--branch NAME` releases a pushed branch other than `main`. The manual steps
below remain available when operating without the orchestration script.

## Check the release workflow before tagging (optional)

For a separate validation without tagging or publishing, run the **Release**
workflow with **Run workflow** on the desired branch. Normal scripted releases
skip this separate run.
This builds and tests both platforms, checks the extracted executables with
`--version` and `--help`, and produces a `release-assets` Actions artifact.
It does not create a tag or a GitHub Release. Pull requests changing the
release configuration or notes also run these checks without publishing.

The artifact contains:

```text
gitframe-vMAJOR.MINOR.PATCH-linux-x86_64.tar.gz
gitframe-vMAJOR.MINOR.PATCH-macos-arm64.tar.gz
SHA256SUMS
```

Each archive contains `gitframe`, `README.md`, `docs/guide.md`, GitFrame's own
`LICENSE`, and `BUILD-INFO.json`. The archive has a single enclosing directory
matching its filename without `.tar.gz`.

## Publish

After the version and release notes have been prepared and pushed, push a
stable `vMAJOR.MINOR.PATCH` tag matching `build.zig.zon`:

```sh
release_tag="$(python3 scripts/release.py version)" &&
release_tag="${release_tag#tag=}" &&
python3 scripts/release.py notes --tag "$release_tag" &&
git tag -a "$release_tag" -m "GitFrame $release_tag" &&
git push origin "$release_tag"
```

Tag pushes build and test both platforms. Only after both succeed and
their checksums are verified does the publish job create a draft, upload all
three assets, and publish it with the matching Markdown release notes. The publish job
alone has `contents: write`; it uses the repository's built-in `GITHUB_TOKEN`.
No paid service or additional secret is required for this public repository.

An interrupted upload can be rerun while the release remains a draft. Before
publishing, the draft body is refreshed from the tagged notes file. A published
release is never overwritten by the workflow. Prerelease tags are not supported yet.

## Update installation instructions and Homebrew

After the GitHub Release is published, use `scripts/update-gitframe.py` in the
[hiroaqii/homebrew-tap](https://github.com/hiroaqii/homebrew-tap) checkout:

```sh
# Run from the homebrew-tap repository; replace MAJOR.MINOR.PATCH with the
# published version (without the v prefix).
python3 scripts/update-gitframe.py MAJOR.MINOR.PATCH --dry-run
python3 scripts/update-gitframe.py MAJOR.MINOR.PATCH
```

This retrieves the published hashes, updates the Formula in a temporary
checkout, commits and pushes an update branch, creates or reuses a PR, and waits
for all three **Install** jobs. It leaves the local checkout untouched and does
not merge the PR. Review and merge the PR to make the new version available
through Homebrew. See the tap README for prerequisites and retry behavior.

Alternatively, update the Formula's version and both SHA-256 hashes manually
from the release's `SHA256SUMS`, then submit a PR. **Install** tests Homebrew and
mise installation on Linux and macOS, including execution without removing
quarantine attributes on macOS.

The [README's mise command](../README.md#mise) uses `@latest`, so it needs no
version edit for each release. mise uses the existing GitHub Release directly
and needs no separate registry update. Its default minimum release age can
exclude a newly published version from `@latest` for 24 hours. Keep the
[source instructions' Zig version](../docs/guide.md#from-source) aligned with
the workflow.

## Local validation

```sh
python3 -m unittest discover -s scripts -p 'release*_test.py' -v
release_tag="$(python3 scripts/release.py version)"
release_tag="${release_tag#tag=}"
python3 scripts/release.py notes --tag "$release_tag"
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux.5.15-gnu.2.35 -Dcpu=baseline
python3 scripts/release.py package --tag "$release_tag" --platform linux-x86_64 \
  --binary zig-out/bin/gitframe --output release
```

Run packaging on the corresponding OS/CPU because it executes the extracted
binary. Build the macOS archive with `-Dtarget=aarch64-macos.15.0` and
`--platform macos-arm64`. Keep the targets in the workflow and `release.py`
aligned when changing the supported environments.
