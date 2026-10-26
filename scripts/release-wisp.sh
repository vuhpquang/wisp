#!/usr/bin/env bash
# Publish a Wisp release on GitHub: build the app (without touching the
# installed one, which updates itself), zip it, tag the commit wisp-v<version>
# and create a release whose notes are the version's section of CHANGELOG.md.
#
# Usage: scripts/release-wisp.sh 0.2.0   (the first version in CHANGELOG.md)
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

if [ "$(sed -n 's/^## \([0-9][0-9.]*\).*/\1/p' CHANGELOG.md | head -1)" != "$version" ]; then
  echo "Add a \"## $version - <date>\" section at the top of CHANGELOG.md first." >&2
  exit 1
fi

# Name the repo explicitly: gh would otherwise pick the upstream remote.
repo="$(git remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"

out="$(mktemp -d)"
WISP_DEST="$out/Wisp.app" WISP_RELEASE_REPO="$repo" ./scripts/install-wisp.sh

zip="$out/Wisp-$version.zip"
echo "==> Packaging $zip"
ditto -c -k --sequesterRsrc --keepParent "$out/Wisp.app" "$zip"

{
  # The version's section of CHANGELOG.md, without its heading.
  awk -v v="$version" '/^## / { on = index($0, "## " v) == 1; next } on' CHANGELOG.md
  echo
  echo "## Install"
  echo
  echo "Download \`Wisp-$version.zip\`, unzip it and move Wisp.app to /Applications. Built for"
  echo "Apple silicon. The app isn't notarized: the first time, right-click it and choose Open,"
  echo "or run \`xattr -dr com.apple.quarantine /Applications/Wisp.app\`. After that Wisp updates"
  echo "itself from these releases. To build it yourself, clone the repo and run"
  echo "\`scripts/install-wisp.sh\`."
} > "$out/notes.md"

echo "==> Tagging $tag"
git tag -a "$tag" -m "Wisp $version"
git push origin "$tag"

echo "==> Creating the GitHub release"
gh release create "$tag" "$zip" --repo "$repo" --title "Wisp $version" --notes-file "$out/notes.md"
