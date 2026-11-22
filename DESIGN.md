---
name: Wisp
platform: macos
appearance: light+dark      # follows the terminal theme / macOS appearance
tokens: none yet
dials:
  variance: 3              # a terminal with a browser-style vertical tab sidebar
  motion: 2                # sidebar slide-in, hover previews; nothing decorative
  density: 7               # compact 10–13 pt sidebar rows with folder, branch and timer details
fonts: system
accent: "system"           # tab and group colours are user-chosen; chrome follows the terminal theme
---

# Wisp design

Wisp is a fork of Ghostty. **This file covers only Wisp's own surfaces**: the vertical tab sidebar
(`macos/Sources/Features/Terminal/TabSidebar/`), SuperNode (`Features/SuperNode/`), Agent Monitor
(`Features/Agent Monitor/`), Share Output, Wisp Settings / Update / About (`Features/Wisp */`). The
terminal itself and Ghostty's own UI are upstream's and change only through weekly merges.

## 1. The look

A fast native terminal whose distinguishing chrome is a **browser-style vertical tab sidebar** on the
left (220 pt default, 150–420 resizable): pinned tabs as tiles at the top, workspaces with emoji or SF
Symbol icons, named coloured tab groups that collapse under their label, and compact tab rows showing
title, folder, git branch and command time, with a red dot for tabs that need attention. It pins, or
collapses and slides in as a floating panel (75 % of the window height) when the mouse touches the
left edge. The sidebar sits on the **terminal's own background colour** (88 % opacity), so it belongs
to whatever theme the user runs. Around it: Agent Monitor (⇧⌘A), SuperNode (a canvas of agent/terminal
nodes with chat, diff, editor and board views), an update banner, Settings and About.

Load-bearing ideas:

1. **Chrome takes the terminal's colours**: `ghostty.config.backgroundColor` behind the sidebar; no
   Wisp palette competes with the user's theme.
2. **Information density in the sidebar**: folder, branch, timer, attention dot — at a glance.
3. **Fork hygiene is part of the design**: Wisp UI lives in its own folders; upstream files get small,
   commented hooks only.

## 2. Identity and references

- **Ghostty** (upstream): the terminal, renderer, config and most macOS UI. Credited in About ("Built
  on Ghostty"). Upstream identifiers (`ghostty_*`, `Ghostty.*`) are never renamed; only user-visible
  text says Wisp.
- **Arc / browser vertical tabs**: the sidebar model (pinned tiles, groups, workspaces, unloading).
  Own implementation and look; nothing copied.
- Wisp keeps its own name and icon; About follows `.claude/rules/app-shell.md` by hand in
  `WispAboutView` (Wisp doesn't use app-shell, so upstream merges stay clean).

## 3. Tokens

**None yet.** Wisp surfaces use literals: fonts mostly `.system(size: 10…13)` (≈ 100 uses), radii
6/7/8/9/12, the terminal background colour, system colours (`systemCyan`, `textBackgroundColor`) and a
few `Material`s. Sidebar geometry constants live on `TabSidebarState` (`defaultWidth` 220,
`widthRange` 150…420, `floatingHeightFraction` 0.75, `revealEdge` 6).

## 4. Typography

System font at fixed small sizes in the sidebar (title ~12–13 pt, details 10–11 pt), monospace in
SuperNode's editor/diff and wherever terminal text is previewed. The terminal's own font is the
user's config.

## 5. Components

- Tab sidebar: `TabSidebar` (container, pin/collapse/float), `TabWorkspaces`, `TabGroups`,
  `TabSelection`, `TabSwitcher`, `TabColorMenu`, `TabIconPicker` (emoji / SF Symbol), `TabSleep`
  (unloading), `TabClosing`, `TabSidebarInfo` (details row). Hover preview of a tab's visible text.
- SuperNode: `SuperNodeCanvasView`, `SuperNodeNodeView`, `SuperNodeBoardView`, `SuperNodeChat`,
  `SuperNodeDiffView`, `SuperNodeEditorView` (+ `SuperNodeSyntax`), `SuperNodePalette`,
  `SuperNodePermissionView`, `SuperNodeUsage`, `SuperNodeWebView`.
- `AgentMonitor` (list of splits running Claude Code / Codex / Gemini / Aider: working, waiting, idle).
- `WispUpdateBanner`, `WispChangelog`, `WispSettings` (+ `WispKeybindings`), `WispAboutView`.

## 6. Layout and density

Sidebar 220 pt (150–420) beside the terminal; floating mode centred vertically at 75 % height,
revealed within 6 pt of the left edge. Dense rows (dial 7). Horizontal tabs remain available from the
tab menu.

## 7. Depth, materials, glass

Sidebar on the terminal background at 0.88 opacity; a few `Material` backgrounds for floating panels
and popovers. No Liquid Glass of Wisp's own.

## 8. Motion

Sidebar slide-in/out when floating, hover previews, list reorders by drag. No Wisp-wide animation
switch (see gaps).

## 9. States

- Attention: red dot on tabs that rang the bell, failed, or finished a long command while away
  (⌘J jumps to the next).
- Unloaded tabs: shown as sleeping; reopen in the same folders and splits.
- Agent states: working / waiting for you / idle.
- Update available: banner in the sidebar; Wisp rebuilds itself from the checkout.

## 10. Do's and don'ts

- Do put Wisp UI in Wisp folders; keep edits to upstream files small and commented.
- Do take colours from the terminal theme for chrome that sits next to the terminal.
- Don't rename upstream identifiers or config options; rename user-visible text only.
- Never quit the owner's running Wisp to test (it's their main terminal).

**Allowed exceptions:**

- *Emoji as icons* for workspaces: user-picked (emoji or SF Symbol), not app decoration.
- *Fixed point sizes* in the sidebar: compact, terminal-adjacent density; see gaps for tokens.

## 11. Render recipe

Debug build in `macos/` (`zig build -Demit-macos-app=false` when Zig changed, then
`xcodebuild -target Ghostty -configuration Debug`). Synthetic mouse events don't reach a background
debug app, so **the owner tests interactions and sends screenshots**.

Not a render step: `scripts/install-wisp.sh` installs a **preview** into `/Applications` for the owner
(keeps the running Wisp; used after its next restart). Run it only when a change is finished, per the
hub's "Preview first" rule — never to look at UI while working.

## 12. Known gaps

- **Render not verified** in this pass (no screenshots; written from code, `README.md` and
  `AGENTS.md`).
- **No token source** for Wisp's surfaces: ≈ 100 fixed font sizes and scattered radii (6/7/8/9/12).
  A small `WispTheme` in a Wisp folder would let new UI stop adding literals.
- No Wisp-wide animation switch / Reduce Motion handling for the sidebar slide-in.
