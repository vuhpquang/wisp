import AppKit

/// Which tab is shown after the selected tab closes. AppKit would pick any tab
/// of the window, including hidden ones of other workspaces, which switches the
/// workspace. With the sidebar we stay in the workspace instead:
///
/// - The tab listed just above the closed one is shown (the one below if it
///   was first). Pinned tiles count as listed above the workspace's tabs.
/// - Closing the last tab of a workspace opens a new tab in the home folder
///   there and asks whether to delete the workspace. Deleting it shows the last
///   tab of the workspace before it (or after it, if it was first).
enum TabClosing {
    /// Called right before `window` closes as a tab.
    static func willClose(_ window: NSWindow) {
        guard let terminal = window as? TerminalWindow,
              terminal.usesVerticalTabs,
              let tabGroup = window.tabGroup,
              tabGroup.selectedWindow === window,
              tabGroup.windows.count > 1 else { return }

        let store = TabWorkspaceStore.shared
        let workspaceID = store.activeID
        let windows = tabGroup.windows
        let pinned = windows.filter(isPinned)
        let listed = sidebarOrder(windows.filter {
            !isPinned($0) && store.workspaceID(of: $0) == workspaceID
        })

        // The workspace keeps tabs: show the neighbor of the closed tab.
        if terminal.isTabPinned || listed.contains(where: { $0 !== window }) {
            let visible = pinned + listed
            guard let index = visible.firstIndex(of: window) else { return }
            let others = visible.filter { $0 !== window }
            if let next = index > 0 ? visible[index - 1] : others.first {
                select(next)
                return
            }
        }

        // No tab of the workspace is left (pinned tabs belong to every workspace).
        guard let placeholder = openHomeTab(from: window) else { return }
        guard store.workspaces.count > 1,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }

        // Ask once the tab has closed, on the tab that replaced it.
        DispatchQueue.main.async {
            askToDelete(workspace, placeholder: placeholder)
        }
    }

    // MARK: Deleting the emptied workspace

    private static func askToDelete(_ workspace: TabWorkspace, placeholder: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Delete Workspace “\(workspace.name)”?"
        alert.informativeText = "Its last tab was closed. Delete the workspace, or keep it with a new tab."
        alert.addButton(withTitle: "Delete Workspace")
        alert.addButton(withTitle: "Keep Workspace")

        alert.beginSheetModal(for: placeholder) { response in
            guard response == .alertFirstButtonReturn else { return }
            delete(workspace.id, placeholder: placeholder)
        }
    }

    private static func delete(_ id: UUID, placeholder: NSWindow) {
        let store = TabWorkspaceStore.shared
        guard store.workspaces.count > 1,
              let index = store.workspaces.firstIndex(where: { $0.id == id }),
              let windows = placeholder.tabGroup?.windows else { return }

        // A tab opened in the workspace while asking: keep it.
        let remaining = windows.filter {
            $0 !== placeholder && !isPinned($0) && store.workspaceID(of: $0) == id
        }
        guard remaining.isEmpty else { return }

        let neighbor = store.workspaces[index > 0 ? index - 1 : index + 1].id
        store.activate(neighbor)

        let candidates = sidebarOrder(windows.filter {
            !isPinned($0) && store.workspaceID(of: $0) == neighbor
        })
        if let last = candidates.last {
            select(last)
        } else {
            // New tabs open in the active workspace, now the neighbor.
            openHomeTab(from: placeholder)
        }

        // Close the placeholder without an undo step: undoing should bring
        // back the tab the user closed, not this empty one.
        if let controller = placeholder.windowController as? TerminalController {
            controller.surfaceTree = .init()
        }
        placeholder.close()

        TabSleepStore.shared.reassign(from: id, to: neighbor)
        store.delete(id)
    }

    // MARK: Helpers

    private static func isPinned(_ window: NSWindow) -> Bool {
        (window as? TerminalWindow)?.isTabPinned == true
    }

    /// Tabs of one workspace in the order the sidebar lists them: a group's
    /// tabs together, where its first tab is.
    private static func sidebarOrder(_ windows: [NSWindow]) -> [NSWindow] {
        let groups = TabGroupStore.shared
        let groupID = { (window: NSWindow) in groups.group((window as? TerminalWindow)?.tabGroupID)?.id }

        var ordered: [NSWindow] = []
        var listed = Set<UUID>()
        for window in windows {
            guard let id = groupID(window) else {
                ordered.append(window)
                continue
            }
            guard listed.insert(id).inserted else { continue }
            ordered += windows.filter { groupID($0) == id }
        }
        return ordered
    }

    private static func select(_ window: NSWindow) {
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        if let surface = (window.windowController as? BaseTerminalController)?.focusedSurface {
            window.makeFirstResponder(surface)
        }
    }

    /// Open a tab in the home folder next to `parent`, in the active workspace.
    @discardableResult
    private static func openHomeTab(from parent: NSWindow) -> NSWindow? {
        guard let ghostty = (parent.windowController as? BaseTerminalController)?.ghostty else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        return TerminalController.newTab(ghostty, from: parent, withBaseConfig: config)?.window
    }
}
