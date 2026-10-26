import AppKit
import SwiftUI

/// Actions on the tabs picked with ⌘- or ⇧-click. Each one forgets the picked
/// tabs afterwards.
extension TabSidebarModel {
    /// The picked tabs, as last reloaded.
    var selectedTabs: [Tab] {
        let ids = selectedIDs
        return ids.compactMap { id in tabs.first { $0.id == id } }
    }

    /// Tabs running a program ask first, one by one.
    func closeSelected() {
        let ids = selectedIDs
        clearSelection()
        for id in ids { close(id) }
    }

    func groupSelected() {
        let ids = selectedTabs.filter { !$0.isPinned }.map(\.id)
        clearSelection()
        promptNewGroup(with: ids)
    }

    /// Put the tabs in a group (nil removes them from theirs).
    func addSelected(toGroup groupID: UUID?) {
        let ids = selectedTabs.filter { !$0.isPinned }.map(\.id)
        clearSelection()
        for id in ids { addTab(id, toGroup: groupID) }
    }

    func moveSelected(toWorkspace workspaceID: UUID) {
        let ids = selectedIDs
        clearSelection()
        for id in ids { moveTab(id, toWorkspace: workspaceID) }
    }

    /// Pin all of them, or unpin all if they're all pinned. They keep their order.
    func togglePinSelected() {
        let tabs = selectedTabs
        let pin = !tabs.allSatisfy(\.isPinned)
        clearSelection()
        // Pinning appends to the pinned tabs, unpinning prepends to the others.
        let changing = tabs.filter { $0.isPinned != pin }
        for tab in pin ? changing : changing.reversed() { togglePin(tab.id) }
    }

    func setColorOfSelected(_ color: TerminalTabColor) {
        let ids = selectedIDs
        clearSelection()
        for id in ids { setColor(color, for: id) }
    }

    func unloadSelected() {
        let ids = selectedTabs.filter { !$0.isPinned }.map(\.id)
        clearSelection()
        for id in ids { unload(id) }
    }
}

/// The context menu of a tab among several picked ones: acts on all of them.
struct TabSelectionMenu: View {
    let model: TabSidebarModel

    var body: some View {
        let tabs = model.selectedTabs
        let unpinned = tabs.filter { !$0.isPinned }
        let colors = Set(tabs.map(\.color))

        Text("\(tabs.count) Tabs Selected")

        Divider()

        Button(tabs.allSatisfy(\.isPinned) ? "Unpin Tabs" : "Pin Tabs", action: model.togglePinSelected)
        Menu("Move Tabs to Workspace") {
            ForEach(TabWorkspaceStore.shared.workspaces) { workspace in
                Button { model.moveSelected(toWorkspace: workspace.id) } label: {
                    TabIconLabel(icon: workspace.icon, title: workspace.name)
                }
            }
        }
        TabColorMenu(color: colors.count == 1 ? colors.first ?? .none : .none, apply: model.setColorOfSelected)

        if !unpinned.isEmpty {
            Divider()

            Button("New Group with Tabs…", action: model.groupSelected)
            let groups = model.visibleGroups
            if !groups.isEmpty {
                Menu("Add Tabs to Group") {
                    ForEach(groups) { group in
                        Button(group.name.isEmpty ? "Unnamed Group" : group.name) {
                            model.addSelected(toGroup: group.id)
                        }
                    }
                }
            }
            if unpinned.contains(where: { $0.groupID != nil }) {
                Button("Remove Tabs from Group") { model.addSelected(toGroup: nil) }
            }

            Divider()

            Button("Unload Tabs", action: model.unloadSelected)
        }

        Button("Close \(tabs.count) Tabs", action: model.closeSelected)

        Divider()

        Button("Deselect Tabs", action: model.clearSelection)
    }
}

/// An accent ring around a picked tab.
struct TabMultiSelectionOutline: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
                .allowsHitTesting(false))
    }
}
