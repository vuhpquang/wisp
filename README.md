<p align="center">
  <img src="macos/Assets.xcassets/AppIconImage.imageset/macOS-AppIcon-256px-128pt@2x.png" alt="Wisp" width="128">
</p>

<h1 align="center">Wisp</h1>

<p align="center">
  A fast, native macOS terminal with vertical tabs, workspaces and an eye on your coding agents.
</p>

---

## Features

**Tabs, the way a browser does them**

- **Vertical tab sidebar**: pin it, collapse it with <kbd>⌘E</kbd>, or let it slide in when the
  mouse touches the left edge. Resize it by dragging its edge. Switch to horizontal tabs from the
  tab menu at any time.
- **Pinned tabs** as tiles at the top, shared by every workspace.
- **Tab groups**: named, colored groups that collapse under their label.
- **Workspaces** with emoji or SF Symbol icons; <kbd>⇧⌘1</kbd>…<kbd>⇧⌘9</kbd> switch between them.
- **Rename in place** by double-clicking a tab, color tabs, drag to reorder, search across
  workspaces, preview a tab's text by hovering it.
- **Unload tabs** you're not using, by hand or automatically after a while. They reopen in the same
  folders and splits.
- **Layouts**: save a workspace's tabs and splits to `~/.config/ghostty/tab-layouts.json`, add a
  command to run per pane, and reopen it in one click.

**Knowing what's going on**

- Each tab shows its folder, git branch and how long its command has been running.
- Tabs that rang the bell, failed, or finished a long command while you were away get a red dot;
  <kbd>⌘J</kbd> jumps to the next one.
- **Agent Monitor** (<kbd>⇧⌘A</kbd>) lists every split running Claude Code, Codex, Gemini or Aider
  with whether it's working, waiting for you or idle.
- **Share a selection** as Markdown or as an image, or ask Claude, Claude Code, Codex or Gemini
  about it in a new split.

**Comfortable**

- **Settings** (<kbd>⌘,</kbd>) for fonts, themes, background, padding, cursor, tabs, keyboard
  shortcuts and the quick terminal. Your config file is never rewritten.
- **Quick terminal** on a global shortcut, sized and placed as you like.
- **In-app updates**: Wisp tells you when there's something new and rebuilds itself.

## Install

Download the latest `Wisp-x.y.z.zip` from [Releases](../../releases), unzip it and move
`Wisp.app` to `/Applications`. It is signed locally, not notarized: the first time, right-click it
and choose **Open**.

### Build from source

You need Xcode and [Zig](https://ziglang.org) 0.17 (`brew install zig`).

```sh
git clone https://github.com/vuhpquang/wisp.git
cd wisp
scripts/setup-wisp-signing.sh   # once: keeps macOS permissions across updates
scripts/install-wisp.sh         # builds and installs /Applications/Wisp.app
```

After that, Wisp updates itself from this checkout: when `main` has new commits, the tab sidebar
shows an **Update** button.

## Configuration

Wisp reads the standard config file at `~/.config/ghostty/config` (or
`~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`). Changes made in the Settings
window go to `~/Library/Application Support/Wisp/settings.ghostty`, which is loaded after your
config. **Open Config File** in Settings opens your config.

Shortcuts you might want to change, in Settings > Keyboard or in the config:

| Shortcut | Action |
| --- | --- |
| <kbd>⌘E</kbd> | Pin or collapse the tab sidebar (`toggle_tab_sidebar`) |
| <kbd>⇧⌘1</kbd>…<kbd>⇧⌘9</kbd> | Switch workspace (`goto_workspace:N`) |
| <kbd>⌘J</kbd> | Next tab needing attention (`goto_attention_tab`) |
| <kbd>⇧⌘A</kbd> | Agent Monitor |
| <kbd>⌘,</kbd> | Settings |

## Releasing

```sh
scripts/release-wisp.sh 0.2.0
```

builds the app, tags `wisp-v0.2.0` and publishes a GitHub release with the changes since the last
one.

## License

MIT. See [LICENSE](LICENSE).
