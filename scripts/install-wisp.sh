#!/usr/bin/env bash
# Build Wisp (this fork of Ghostty) as an optimized, locally signed app and
# install it to /Applications/Wisp.app. Run it again after pulling changes.
#
# Options:
#   --pull     fast-forward the checkout from origin/main first
#   --quit     quit a running Wisp before installing (its terminals close);
#              by default it keeps running and the new version is used after
#              the next restart
#
# Wisp never auto-updates through Sparkle: it would be replaced by upstream
# Ghostty. The in-app updater runs this script instead. Your Ghostty config
# keeps working as is.
set -euo pipefail

pull=false
quit=false
for arg in "$@"; do
  case "$arg" in
    --pull) pull=true ;;
    --quit) quit=true ;;
    --no-quit) quit=false ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Apps launched from Finder get a minimal PATH; zig comes from Homebrew.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

cd "$(dirname "$0")/.."
source_dir="$(pwd)"

dest="/Applications/Wisp.app"
built="macos/build/ReleaseLocal/Ghostty.app"

if $pull; then
  echo "==> Pulling origin/main"
  git pull --ff-only origin main
fi

# libghostty embeds its version, which by default includes the current commit,
# so every commit would rebuild it from scratch (minutes, with optimizations).
# Use the last commit that touched the Zig/C sources instead: commits that only
# change the macOS app reuse the cached library.
base_version="$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon | head -1)"
lib_commit="$(git log -1 --format=%h -- src include pkg vendor build.zig build.zig.zon)"
lib_version="${base_version}+${lib_commit}"

echo "==> Building libghostty $lib_version (ReleaseFast, this Mac's architecture)"
zig build -Doptimize=ReleaseFast -Demit-macos-app=false \
  -Dxcframework-target=native -Dversion-string="$lib_version"

echo "==> Building the macOS app (ReleaseLocal)"
# Match the single-architecture library built above.
(cd macos && xcodebuild -target Ghostty -configuration ReleaseLocal -arch "$(uname -m)" build -quiet)

if $quit && [ "$(osascript -e 'application id "com.vuhpquang.wisp" is running' 2>/dev/null)" = "true" ]; then
  echo "==> Quitting the running Wisp"
  osascript -e 'tell application id "com.vuhpquang.wisp" to quit' || true
  sleep 2
fi

echo "==> Installing to $dest"
rm -rf "$dest"
cp -R "$built" "$dest"

# The generated Info.plist names the bundle after the Xcode target, which the
# menu bar shows, so rename it here. The commit and source folder let the
# in-app updater find new commits and rebuild. Then sign the app again.
plist="$dest/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Wisp" "$plist"
/usr/libexec/PlistBuddy -c "Add :WispCommit string $(git rev-parse HEAD)" "$plist"
/usr/libexec/PlistBuddy -c "Add :WispSourcePath string $source_dir" "$plist"
codesign --force --sign - --options runtime \
  --entitlements macos/GhosttyReleaseLocal.entitlements "$dest"

echo "==> Done. Restart Wisp to use the new version."
