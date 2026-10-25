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

out="$(mktemp -d)"
WISP_DEST="$out/Wisp.app" ./scripts/install-wisp.sh

zip="$out/Wisp-$version.zip"
echo "==> Packaging $zip"
ditto -c -k --sequesterRsrc --keepParent "$out/Wisp.app" "$zip"

{
  # The version's section of CHANGELOG.md, without its heading.
  awk -v v="$version" '/^## / { on = index($0, "## " v) == 1; next } on' CHANGELOG.md
  echo
  echo "## Install"
  echo
  echo "Unzip and move Wisp.app to /Applications. The app isn't notarized: the"
  echo "first time, right-click it and choose Open. To build it yourself (and get"
  echo "in-app updates), clone the repo and run \`scripts/install-wisp.sh\`."
} > "$out/notes.md"

echo "==> Tagging $tag"
git tag -a "$tag" -m "Wisp $version"
git push origin "$tag"

echo "==> Creating the GitHub release"
# Name the repo explicitly: gh would otherwise pick the upstream remote.
repo="$(git remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
gh release create "$tag" "$zip" --repo "$repo" --title "Wisp $version" --notes-file "$out/notes.md"
