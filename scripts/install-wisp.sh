#!/usr/bin/env bash
# Build Wisp (this fork of Ghostty) as an optimized, locally signed app and
# install it to /Applications/Wisp.app. Run it again after pulling changes.
#
# Wisp never auto-updates: Sparkle is disabled so it can't be replaced by
# upstream Ghostty. Your Ghostty config keeps working as is.
set -euo pipefail

cd "$(dirname "$0")/.."

dest="/Applications/Wisp.app"
built="macos/build/ReleaseLocal/Ghostty.app"

echo "==> Building libghostty (ReleaseFast)"
zig build -Doptimize=ReleaseFast -Demit-macos-app=false

echo "==> Building the macOS app (ReleaseLocal)"
(cd macos && xcodebuild -target Ghostty -configuration ReleaseLocal build -quiet)

if [ "$(osascript -e 'application id "com.vuhpquang.wisp" is running' 2>/dev/null)" = "true" ]; then
  echo "==> Quitting the running Wisp"
  osascript -e 'tell application id "com.vuhpquang.wisp" to quit' || true
  sleep 2
fi

echo "==> Installing to $dest"
rm -rf "$dest"
cp -R "$built" "$dest"

# The generated Info.plist names the bundle after the Xcode target, which the
# menu bar shows, so rename it here and sign the app again.
/usr/libexec/PlistBuddy -c "Set :CFBundleName Wisp" "$dest/Contents/Info.plist"
codesign --force --sign - --options runtime \
  --entitlements macos/GhosttyReleaseLocal.entitlements "$dest"

echo "==> Done. Open it with: open -a Wisp"
