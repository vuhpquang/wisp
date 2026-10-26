# Changelog

Wisp's own changes. The terminal underneath follows upstream Ghostty, merged weekly.
Wisp shows the new sections of this file after it updates itself; the build scripts
take the version from the first heading.

## 0.2.1 - 2026-10-26

### Select several tabs
- Shift-click a tab to select every tab from the current one to it; Cmd-click adds or removes a
  single tab. The tab you're looking at stays the same.
- Right-click a selected tab to act on all of them: pin, move to a workspace, set a color, put
  them in a new or existing group, take them out of their group, unload or close them.
- Drag a selected tab to move all of them together.

### Tab colors
- More colors, in rainbow order, with a swatch next to each one in the Tab Color menu.

## 0.2.0 - 2026-10-25

### Tab groups, like Firefox
- Group related tabs under a colored label: right-click a tab → Add Tab to Group → New Group…
- Drag a group's label to move all its tabs together.
- Drag tabs in and out of groups: drop a tab among a group's tabs, or on the lower part of its
  label, to add it; drop it among ungrouped tabs, above a group, on the workspace name or below
  the list to take it out.
- While you drag, a line shows where the tab will land: in the group's color when it will join
  that group, light gray otherwise.
- Click a label to collapse or expand its group, now animated.
- New groups and **Edit Group…** open a panel with the name, a row of colors and the group's
  actions (New Tab in Group, Ungroup Tabs, Close Group).
- Labels look like Firefox's: a light, drop-shaped label with dark text. Choose **Solid** for a
  colored pill instead (right-click the sidebar → Group Labels, or Settings → Tabs).

### Sidebar
- Double-click a tab to rename it in place.
- Right-click the empty part of the sidebar for New Tab, New Workspace, the folder/branch details,
  hover previews, idle tab unloading, the layout options, Agent Monitor and Settings.

### Share Selection with an AI
- Right-click selected output → Share Selection → ask Claude, or start Claude Code, Codex or
  Gemini CLI in a new split with the selection as the first message. Only installed apps and
  CLIs are listed.

### Settings and the quick terminal
- Settings switches panes with a toolbar, like other macOS settings windows.
- Set the quick terminal's size along its edge and its centered width or height, and pick ⌥` as
  its global shortcut.
- Size and position changes now apply to the quick terminal right away.

### Updates
- After updating itself, Wisp shows what's new in a window like this one.
- Wisp is signed with a stable certificate when one is available
  (`scripts/setup-wisp-signing.sh`), so macOS keeps its permissions, such as Accessibility,
  across updates.

### Fixes
- Collapsing or recoloring a group didn't redraw the sidebar.
- A layout's tabs opened in reverse order.
- An unloaded tab came back after the selected tab and outside its group; it now returns to its
  place.
- The quick terminal's Height showed blank after choosing a Width.

## 0.1.0 - 2026-10-24

The first release of Wisp, a macOS terminal for working with many projects and AI agents at once.

### Vertical tab sidebar
- Tabs in a sidebar instead of a tab bar: ⌘E pins it or tucks it away (touch the left edge to
  bring it back), drag its edge to resize it, and switch to horizontal tabs from the tab menu.
- Pinned tabs sit as tiles at the top and show in every workspace.
- Each tab shows its folder, git branch and how long its command has been running, with ✓ or ✗
  when a long command finishes.
- Tabs that need you (a bell, an error, a finished command) get a red dot; ⌘J jumps to the next
  one, even in another workspace.
- Search tabs across workspaces, and preview a tab's text by hovering it.

### Workspaces and layouts
- Workspaces with an emoji or SF Symbol icon; ⇧⌘1…9 switches between them.
- Save a workspace as a layout and open it again later, splits and commands included
  (`~/.config/ghostty/tab-layouts.json`).

### Unloading tabs
- Unload a tab you aren't using to free its shell and memory, or unload idle tabs automatically.
  Click it to reopen it in the same folders and splits.

### Agents
- Claude Code, Codex and Gemini CLI show their state in the sidebar: working, idle, or waiting
  for you.
- Agent Monitor (⇧⌘A) lists every agent and takes you to it.
- Share selected output as Markdown or as an image.

### Settings and updates
- A Settings window (⌘,) for the common options, shortcuts and the quick terminal, with Reload
  Config and Restart Wisp.
- Wisp updates itself from its source checkout: it checks for new commits, then rebuilds and
  reinstalls when you click Update.
- A new app icon and name.
