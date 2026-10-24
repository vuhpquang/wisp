#!/usr/bin/env bash
# Publish a Wisp release on GitHub: build and install the app, zip it, tag the
# commit wisp-v<version> and create a release listing the Wisp changes since
# the previous release (upstream Ghostty commits are left out).
#
# Usage: scripts/release-wisp.sh 0.2.0
set -euo pipefail

version="${1:?usage: scripts/release-wisp.sh <version>, e.g. 0.2.0}"
tag="wisp-v$version"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
  echo "Commit your changes first." >&2
  exit 1
fi

git fetch --quiet origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Release from main as pushed: check out main and push it first." >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "$tag already exists." >&2
  exit 1
fi

./scripts/install-wisp.sh

out="$(mktemp -d)"
zip="$out/Wisp-$version.zip"
echo "==> Packaging $zip"
ditto -c -k --sequesterRsrc --keepParent /Applications/Wisp.app "$zip"

# Wisp's own commits since the last release, without upstream's.
previous="$(git tag -l 'wisp-v*' --sort=-v:refname | head -1)"
exclude=()
if git remote get-url upstream >/dev/null 2>&1; then
  git fetch --quiet upstream main
  exclude=(^upstream/main)
fi
range=(HEAD)
[ -n "$previous" ] && range=("$previous..HEAD")

{
  echo "## Changes"
  echo
  git log --no-merges --format="- %s" "${range[@]}" ${exclude[@]+"${exclude[@]}"}
  echo
  echo "## Install"
  echo
  echo "Unzip and move Wisp.app to /Applications. The app is signed ad hoc, not"
  echo "notarized: the first time, right-click it and choose Open. To build it"
  echo "yourself, clone the repo and run \`scripts/install-wisp.sh\`."
} > "$out/notes.md"

echo "==> Tagging $tag"
git tag -a "$tag" -m "Wisp $version"
git push origin "$tag"

echo "==> Creating the GitHub release"
gh release create "$tag" "$zip" --title "Wisp $version" --notes-file "$out/notes.md"
