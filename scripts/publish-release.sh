#!/usr/bin/env bash
set -euo pipefail

tag="${1:?usage: publish-release.sh TAG ASSET_DIRECTORY}"
asset_dir="${2:?usage: publish-release.sh TAG ASSET_DIRECTORY}"

notes_file=$(python3 scripts/release.py notes --tag "$tag")
(
  cd "$asset_dir"
  sha256sum --check SHA256SUMS
)
assets=(
  "$asset_dir/gitframe-$tag-linux-x86_64.tar.gz"
  "$asset_dir/gitframe-$tag-macos-arm64.tar.gz"
  "$asset_dir/SHA256SUMS"
)
for asset in "${assets[@]}"; do
  test -s "$asset"
done

# Resume an interrupted upload only while the release is still a draft.
if draft=$(gh release view "$tag" --json isDraft --jq .isDraft); then
  if [[ "$draft" != true ]]; then
    echo "Release $tag is already published; refusing to replace its assets." >&2
    exit 1
  fi
else
  gh release create "$tag" --verify-tag --draft \
    --title "GitFrame $tag" --notes-file "$notes_file"
fi

gh release upload "$tag" "${assets[@]}" --clobber
# All assets are uploaded before the release becomes visible. Also refresh the
# notes when resuming a draft, so the published body matches the tagged file.
gh release edit "$tag" --notes-file "$notes_file" --draft=false
