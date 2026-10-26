import AppKit
import SwiftUI

/// ⌘P: the command palette listing every tab of the window, in every
/// workspace, most recently used first, like VS Code's Go to File. Unloaded
/// tabs follow, and picking one opens it again.
final class TabSwitcher: ObservableObject {
    static let shared = TabSwitcher()

    /// Windows whose command palette shows tabs instead of commands.
    @Published private var windows: Set<ObjectIdentifier> = []

    func isShowing(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return windows.contains(ObjectIdentifier(window))
    }

    func hide(in window: NSWindow?) {
        guard let window else { return }
        windows.remove(ObjectIdentifier(window))
    }

    /// Show the tabs in the palette, switch an open command palette over to
    /// them, or close the palette if it already shows them. Returns false if
    /// the window has no tab sidebar so the keybinding can fall through.
    func toggle(_ controller: BaseTerminalController) -> Bool {
        guard let window = controller.window as? TerminalWindow,
              window.usesVerticalTabs,
              window.tabSidebarModel != nil else { return false }

        if !controller.commandPaletteIsShowing {
            windows.insert(ObjectIdentifier(window))
            controller.toggleCommandPalette(nil)
        } else if isShowing(in: window) {
            controller.commandPaletteIsShowing = false
        } else {
            // The palette view is rebuilt with the tab list and a fresh query.
            controller.commandPaletteIsShowing = false
            DispatchQueue.main.async { [weak self] in
                self?.windows.insert(ObjectIdentifier(window))
                controller.toggleCommandPalette(nil)
            }
        }
        return true
    }

    /// The window's tabs, the shown one last so the first row is the tab used
    /// before it, then its unloaded tabs.
    func options(for window: NSWindow?) -> [CommandOption] {
        guard let window = window as? TerminalWindow, let model = window.tabSidebarModel else { return [] }

        let selected = window.tabGroup?.selectedWindow ?? window
        let tabs = (window.tabGroup?.windows ?? [window])
            .compactMap { $0 as? TerminalWindow }
            .sorted { lhs, rhs in
                if (lhs === selected) != (rhs === selected) { return rhs === selected }
                return lhs.lastViewedAt > rhs.lastViewedAt
            }

        let open = tabs.map { tab in
            CommandOption(
                title: tab.title.isEmpty ? "👻" : tab.title,
                subtitle: Self.subtitle(
                    workspace: tab.isTabPinned ? nil : TabWorkspaceStore.shared.workspaceID(of: tab),
                    directory: (tab.windowController as? BaseTerminalController)?.focusedSurface?.pwd,
                    note: tab.isTabPinned ? "Pinned" : nil),
                leadingIcon: "terminal",
                leadingColor: tab.tabColor.displayColor.map { Color(nsColor: $0) },
                sortKey: ObjectIdentifier(tab)
            ) {
                if !tab.isTabPinned { TabWorkspaceStore.shared.activate(TabWorkspaceStore.shared.workspaceID(of: tab)) }
                model.select(ObjectIdentifier(tab))
            }
        }

        let sleeping = TabSleepStore.shared.tabs.map { tab in
            CommandOption(
                title: tab.title,
                subtitle: Self.subtitle(workspace: tab.workspaceID, directory: tab.directory, note: "Unloaded"),
                leadingIcon: "moon.zzz"
            ) {
                model.wake(tab.id)
            }
        }

        return open + sleeping
    }

    /// The workspace and folder of a tab, e.g. `Work · ~/code/wisp`.
    private static func subtitle(workspace: UUID?, directory: String?, note: String?) -> String? {
        let name = workspace.flatMap { id in TabWorkspaceStore.shared.workspaces.first { $0.id == id }?.name }
        let folder = directory.flatMap { $0.isEmpty ? nil : ($0 as NSString).abbreviatingWithTildeInPath }
        let parts = [note, name, folder].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
