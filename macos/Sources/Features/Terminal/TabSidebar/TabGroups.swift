import AppKit
import Combine
import SwiftUI

/// A named, colored group of tabs in the sidebar, like Firefox's tab groups.
/// Its tabs are kept next to each other and can be collapsed under its label.
struct TabGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var color: TerminalTabColor
    var isCollapsed = false
}

final class TabGroupStore: ObservableObject {
    static let shared = TabGroupStore()

    private static let key = "TabGroups"

    /// Colors given to new groups in turn.
    private static let palette: [TerminalTabColor] = [.blue, .purple, .orange, .green, .pink, .teal, .yellow, .red]

    @Published private(set) var groups: [TabGroup] {
        didSet { save() }
    }

    private init() {
        groups = UserDefaults.ghostty.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([TabGroup].self, from: $0) } ?? []
    }

    func group(_ id: UUID?) -> TabGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    @discardableResult
    func create(name: String) -> TabGroup {
        let color = Self.palette[groups.count % Self.palette.count]
        let group = TabGroup(name: name, color: color)
        groups.append(group)
        return group
    }

    func update(_ id: UUID, _ change: (inout TabGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        change(&groups[index])
    }

    func delete(_ id: UUID) {
        groups.removeAll { $0.id == id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.ghostty.set(data, forKey: Self.key)
    }
}

// MARK: - Views

/// A group's label: a pill in the group's color. Clicking it collapses or
/// expands the group.
struct TabGroupLabel: View {
    let group: TabGroup
    let count: Int
    let model: TabSidebarModel
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(group.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if group.isCollapsed {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.25)))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(nsColor: group.color.displayColor ?? .systemGray)))

            Spacer(minLength: 0)

            if isHovering {
                Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { model.toggleCollapsed(group.id) }
        .help(group.isCollapsed ? "Show tabs" : "Hide tabs")
        .contextMenu {
            Button("Rename Group…") { model.promptRenameGroup(group) }
            Menu("Color") {
                ForEach(TerminalTabColor.allCases.filter { $0 != .none }, id: \.self) { color in
                    Button(color.localizedName) { TabGroupStore.shared.update(group.id) { $0.color = color } }
                }
            }
            Button(group.isCollapsed ? "Expand Group" : "Collapse Group") { model.toggleCollapsed(group.id) }
            Divider()
            Button("New Tab in Group") { model.newTab(inGroup: group.id) }
            Divider()
            Button("Ungroup Tabs") { model.ungroup(group.id) }
            Button("Close Group") { model.closeGroup(group.id) }
        }
    }
}

/// "Add Tab to Group" in a tab's menu.
struct TabGroupMenu: View {
    let tab: TabSidebarModel.Tab
    let model: TabSidebarModel
    @ObservedObject private var store = TabGroupStore.shared

    var body: some View {
        Menu("Add Tab to Group") {
            Button("New Group…") { model.promptNewGroup(with: tab.id) }
            let others = model.visibleGroups.filter { $0.id != tab.groupID }
            if !others.isEmpty { Divider() }
            ForEach(others) { group in
                Button(group.name) { model.addTab(tab.id, toGroup: group.id) }
            }
        }
        if tab.groupID != nil {
            Button("Remove from Group") { model.addTab(tab.id, toGroup: nil) }
        }
    }
}
