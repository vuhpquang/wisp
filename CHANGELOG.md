# Changelog

Wisp's own changes. The terminal underneath follows upstream Ghostty, merged weekly.
Wisp shows the new sections of this file after it updates itself; the build scripts
take the version from the first heading.

## 0.3.3 - 2026-11-11

### Terminal (updated from upstream)
- Resizing a window taller and narrower at once pulls scrollback down correctly again, and a
  resize that widens columns no longer leaves the cursor or selection pointing at the wrong cell.
- Rows that failed to redraw (for example under memory pressure) are retried instead of staying stale.
- Text with an invalid UTF-8 byte still shows everything before the bad byte, and fast text
  decoding works again on CPUs with AVX-512.
- `ssh` terminfo install runs under `sh`, so it works when your login shell on the server is fish
  or another non-POSIX shell; the terminfo entry has a clearer description.
- Updated colour themes.

## 0.3.2 - 2026-11-07

### Tabs and workspaces
- Closing a tab shows the tab listed just above it (or below, if it was first), pinned tiles
  included, and you stay in the same workspace instead of jumping to another one.
- Closing the last tab of a workspace opens a new tab in your home folder there and asks whether
  to delete the workspace. Deleting it takes you to the last tab of the workspace next to it.

## 0.3.1 - 2026-11-07

### Process Monitor
- Window > Process Monitor (also in the sidebar menu) lists every process on the Mac with its CPU,
  memory, threads, running time, user and command line. Search it, sort it, narrow it to your
  processes or the ones Wisp started, and Quit or Force Quit from there. The header shows memory
  and swap for the whole Mac.
- Its SuperNode tab adds up what SuperNode runs, node by node, including projects that aren't open.
- Force Close SuperNode (there, or in the SuperNode project menu) stops all of it at once. Kill
  Processes keeps your canvases and brings agents back as plain shells; Kill & Delete Everything
  also deletes every project.

### Tabs and workspaces
- Drag a workspace in the workspace bar to reorder it. The order also decides the ⇧⌘1… shortcuts.
- ⌘1… now count pinned tabs first, so the numbers match the tiles at the top of the sidebar.
- A tab that hasn't been renamed shows just its last folder (/mini-app) instead of a cut-off path.
- The folder and branch line under a tab can now be turned off from the tab menu and from
  Settings > Tabs.

### About
- The About window is now Wisp's own: its icon, the commit it was built from, a Check for Updates
  button and links to the repo, changelog and issue tracker, with credit to Ghostty.

### Terminal
- Caught up with upstream Ghostty after the weekly merge stalled on a conflict, including a new
  action to switch the window theme for the session.

## 0.3.0 - 2026-11-01

### SuperNode mode
- Turn on the SuperNode switch in the top-right corner of a window (or Window > SuperNode Mode,
  ⌃⌘N) to see your terminals as nodes on an infinite canvas. Turn it off to go back to your tabs;
  the canvas and everything running on it stays. The SuperNode window keeps its own size and
  place, separate from your terminal windows.
- Add terminals, Claude Code, Codex and Gemini agents, notes, diffs and groups from the bar at the
  bottom, by right-clicking the canvas, or by double-clicking it for a terminal.
- Drag the link icon on a node to another node to connect them, and double-click a connection to
  label how they relate. Right-click a connection between two terminals to send one's output to
  the other, or between a note and a terminal to send the note.
- Claude Code agent nodes report through hooks, without touching your Claude settings: RUNNING
  (with the tool in use and how many subagents run), NEEDS YOU, DONE and IDLE. When Claude asks
  for permission, Allow or Deny it from the bar over the node, or in the terminal as usual.
  Plans and questions are answered there too: read Claude's plan and approve it (keeping the
  mode, auto-accepting edits or asking before each), or send it back with what to change; pick
  answers to its questions, including several at once or your own text. A
  notification tells you when an agent needs you or finishes, unless you're looking at it.
  Agents reopen their own conversation after a relaunch.
- Connected agents know about each other. A Claude agent is told what it's connected to on the
  canvas (other agents, terminals, notes, diffs, files, pages, and the labels on the
  connections) and where Wisp keeps a digest of each one's recent conversation or output, so
  it can read what the other is doing when it needs to.
- Right-click a Claude agent and choose Branch Conversation to continue a copy of its
  conversation in a new node, going a different way.
- Right-click a group and choose Work in a New Git Worktree to give it its own branch in its
  own folder; new terminals and agents in the group start there, so several agents can work on
  the same repository without stepping on each other. Remove the worktree from the same menu.
- Subagents an agent starts show as cards under it while they run, and a small bar on each
  agent shows how full its context window is.
- ⌘⇧B (or the board button) turns the canvas into a board: terminals, agents and notes are cards
  in To Do, In Progress, Review and Done, showing their status and last lines of output. Drag
  cards between columns while they keep running, add or rename columns, and open a card for the
  live terminal beside its priority, due date, description and comments.
- Splitting a terminal (⌘D) opens a connected node beside it; ⌘T opens a new node and ⌘W
  closes one.
- A diff node works like an editor's source control panel: it lists staged changes and changes,
  shows the patch of the file you pick with line numbers and code colors, and stages, unstages or
  discards a single hunk, a file or everything (new files go to the Trash). Commit from its message field, push, pull, and switch or create
  branches. Click ± on a terminal to open one for its folder; it refreshes as you work.
- Editor nodes open files with line numbers and code colors for common languages. ⌘S saves,
  ⌘F finds. Double-click a file in a diff to
  open it at its first change, open files from the bar or a terminal's menu, or drop files on the
  canvas (dropped folders open a terminal there). When an agent changes an open file, the editor
  reloads it, or marks it CHANGED ON DISK if you have unsaved edits.
- Web nodes show a page beside your terminals, with an address bar, back and forward. When a
  terminal prints a local address, such as a dev server's http://localhost:3000, a globe button
  on it opens the page in a connected web node.
- Projects: each one is a canvas of its own. Switch, add, rename or delete them from the menu
  at the top left. The canvas you had becomes the Default project, and terminals keep running
  in projects you aren't looking at.
- A chat panel (⌘J, or the chat button) talks to Claude Code, signed in as your Claude Code.
  Ask it to change the canvas in your own words: create, edit and delete nodes, connect them,
  type into terminals, group nodes, move to a node, fit the canvas, or tidy it along its
  connections. It works through a `supernode` command that is the only shell command it may
  run. Each project keeps its own conversation; pick the model at the top of the panel (Sonnet
  by default). Claude Code starts when the panel opens and stays running, and several changes
  go in one step, so a request with several changes takes seconds, not minutes.
- ⌘K opens a command palette: type to jump to any node, run a canvas command, or switch project.
- ⌘Z and ⇧⌘Z undo and redo canvas changes: adding, closing, moving, resizing, connecting,
  renaming and recoloring nodes. A closed agent comes back resuming its conversation.
- Pan by scrolling or dragging the canvas, zoom by pinching or ⌘-scrolling. The minimap in the
  corner shows the whole canvas; click or drag in it to move there. Moving a group moves the
  nodes inside it. The canvas is saved between launches.
- With tmux installed, every terminal on the canvas runs in its own tmux session and keeps
  running when you quit Wisp: open Wisp again and the node is right where it was, agent and all.
  Its scrollback is saved too, so after the Mac restarts the node comes back in its folder with
  its history, and agents resume their conversation. Closing a node ends its session. Turn it off
  for new terminals by right-clicking the canvas. Your own tmux and ~/.tmux.conf aren't touched.

## 0.2.4 - 2026-10-26

### Updates
- Wisp downloaded from GitHub Releases now updates itself: it checks for a new release, and
  Update downloads it and replaces the app. Builds from a checkout still pull and rebuild.

## 0.2.3 - 2026-10-26

### Fixes
- With Tab Colors set to Dot, the horizontal tab bar no longer fills colored tabs either.

## 0.2.2 - 2026-10-26

### Jump to tabs from the keyboard
- ⌘P lists every tab in every workspace, most recently used first, like VS Code's Go to File.
  Type to filter by title, workspace or folder, then press Return. Unloaded tabs are listed too
  and open again when picked.
- ⌘L puts the cursor in the sidebar's search field, showing a collapsed sidebar while you type.
  Escape goes back to the terminal.
- ⌘⇧P still opens the command palette, which now also has Go to Tab… and Search Tabs.

### Tab colors
- Show a tab's color as a filled background or as a small dot before its title: right-click
  the sidebar and pick Tab Colors, or set it in Settings.

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
