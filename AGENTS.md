# Agent Development Guide

A file for [guiding coding agents](https://agents.md/) working on Wisp.

## Commands

- **Build the core library** (needed after changing anything in `src/`, `include/` or `pkg/`):
  `zig build -Demit-macos-app=false -Dxcframework-target=native`
- **Build the macOS app (debug):**
  `cd macos && xcodebuild -target Ghostty -configuration Debug -arch arm64`
  - Output: `macos/build/Debug/Ghostty.app`
- **Build and install the release app:** `scripts/install-wisp.sh`
  - It does not quit a running Wisp; the new version is used after a restart.
- **Test (Zig):** `zig build test -Demit-macos-app=false -Dtest-filter=<test name>`
  - Prefer targeted tests; the full suite is slow.
  - `-Dtest-filter="ghostty.h"` checks that `include/ghostty.h` matches the Zig action enums.
- **Test (macOS):** `cd macos && xcodebuild test -scheme Ghostty -only-testing:GhosttyTests/<Suite>`
- **Validate a config file:** `/Applications/Wisp.app/Contents/MacOS/ghostty +validate-config --config-file=<path>`
- **Formatting:** `zig fmt src` for Zig.

## Code

- Shared core (terminal, renderer, config, keybindings): `src/`
- macOS app: `macos/`
- Wisp's own features live in their own folders so upstream merges stay easy:
  - `macos/Sources/Features/Terminal/TabSidebar/`: sidebar, workspaces, groups, layouts, unloading
  - `macos/Sources/Features/Wisp Settings/`: Settings window, keyboard and quick terminal panes
  - `macos/Sources/Features/Wisp Update/`: in-app updater
  - `macos/Sources/Features/Agent Monitor/`, `macos/Sources/Features/Share Output/`
- New keybinding actions go through `src/input/Binding.zig`, `src/apprt/action.zig`,
  `include/ghostty.h` (append to the end of `ghostty_action_tag_e`), `src/Surface.zig`,
  `src/input/command.zig`, the GTK unimplemented list and `macos/Sources/Ghostty/Ghostty.App.swift`.

## Keeping up with upstream

`.github/workflows/sync-upstream.yml` merges the upstream terminal weekly. To keep those merges
clean:

- Don't rename upstream identifiers (`ghostty_*`, `Ghostty.*`, the `Ghostty` Xcode target, config
  option names, `xterm-ghostty`). Rename user-visible text only.
- Prefer adding new files over editing upstream ones, and keep edits to upstream files small and
  commented.

## Commits

- Commit each finished change on `main` with a message explaining why.
- Push only when asked.
