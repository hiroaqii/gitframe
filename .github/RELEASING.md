# GitHub Releases

The Release workflow builds with Zig 0.16.0 and `ReleaseSafe`:

| Asset platform | Build and test runner | Zig target | CPU |
| --- | --- | --- | --- |
| `linux-x86_64` | `ubuntu-22.04` | `x86_64-linux.5.15-gnu.2.35` | `baseline` |
| `macos-arm64` | `macos-15` | `aarch64-macos.15.0` | `baseline` |

Linux requires kernel 5.15+ and glibc 2.35+. macOS requires macOS 15+ on Apple
Silicon. Both require Git at runtime. The macOS binary is not Developer ID
signed or notarized; browser downloads can require a Gatekeeper override.

## Prepare the version and release notes

For every release, update the version in `build.zig.zon` and write the release
body in `.github/release-notes/vMAJOR.MINOR.PATCH.md`. For example, `v0.1.1`
requires `.github/release-notes/v0.1.1.md`. Commit and push both changes before
running the workflow or creating the tag.

The Markdown file is used as the complete release body. No generated changelog
is appended. A missing, empty, or whitespace-only file stops the workflow
before building, and the publish script checks it again before accessing
GitHub. The notes are read from the same commit as the release tag.

## Check the release workflow before tagging

Run the **Release** workflow with **Run workflow** on the desired branch.
This builds and tests both platforms, checks the extracted executables with
`--version` and `--help`, and produces a `release-assets` Actions artifact.
It does not create a tag or a GitHub Release. Pull requests changing the
release configuration or notes also run these checks without publishing.

The artifact contains:

```text
gitframe-v0.1.0-linux-x86_64.tar.gz
gitframe-v0.1.0-macos-arm64.tar.gz
SHA256SUMS
```

Each archive contains `gitframe`, `README.md`, GitFrame's own `LICENSE`, and
`BUILD-INFO.json`. The archive has a single enclosing directory matching its
filename without `.tar.gz`.

## Publish

After the artifacts and release documentation have been checked, push a
stable `vMAJOR.MINOR.PATCH` tag matching `build.zig.zon`. For the first release:

```sh
git tag -a v0.1.0 -m "GitFrame v0.1.0"
git push origin v0.1.0
```

Tag pushes build and test both platforms again. Only after both succeed and
their checksums are verified does the publish job create a draft, upload all
three assets, and publish it with the matching Markdown release notes. The publish job
alone has `contents: write`; it uses the repository's built-in `GITHUB_TOKEN`.
No paid service or additional secret is required for this public repository.

An interrupted upload can be rerun while the release remains a draft. Before
publishing, the draft body is refreshed from the tagged notes file. A published
release is never overwritten by the workflow. Prerelease tags are not supported yet.

## Local validation

```sh
python3 -m unittest discover -s scripts -p 'release_test.py' -v
python3 scripts/release.py version --tag v0.1.0
python3 scripts/release.py notes --tag v0.1.0
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux.5.15-gnu.2.35 -Dcpu=baseline
python3 scripts/release.py package --tag v0.1.0 --platform linux-x86_64 \
  --binary zig-out/bin/gitframe --output release
```

Run packaging on the corresponding OS/CPU because it executes the extracted
binary. Build the macOS archive with `-Dtarget=aarch64-macos.15.0` and
`--platform macos-arm64`. Keep the targets in the workflow and `release.py`
aligned when changing the supported environments.
