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

/// How group labels look: Firefox's drop (rounded but for the corner the
/// group's tabs hang from) in a light color with dark text, or a solid pill
/// with white text.
enum TabGroupLabelStyle: String, CaseIterable {
    case firefox
    case solid

    var title: String {
        switch self {
        case .firefox: "Light (Firefox)"
        case .solid: "Solid"
        }
    }
}

/// A group's label: a pill in the group's color. Clicking it collapses or
/// expands the group; it can be dragged to move the whole group, and tabs
/// dropped on it join the group.
struct TabGroupLabel: View {
    let group: TabGroup
    let count: Int
    let model: TabSidebarModel
    @ObservedObject private var state = TabSidebarState.shared
    @State private var isHovering = false

    private var color: NSColor { group.color.displayColor ?? .systemGray }

    var body: some View {
        HStack(spacing: 6) {
            pill

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, 4)
        .frame(height: state.groupLabelStyle == .firefox ? 36 : 30)

        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { model.toggleCollapsed(group.id) }
        .help(group.isCollapsed ? "Show tabs" : "Hide tabs")
        .popover(isPresented: Binding(
            get: { model.editingGroup?.id == group.id },
            set: { if !$0 { model.endEditingGroup() } }
        ), arrowEdge: .trailing) {
            TabGroupEditor(groupID: group.id, isNew: model.editingGroup?.isNew ?? false, model: model)
        }
        .contextMenu {
            Button("Edit Group…") { model.editGroup(group.id) }
            Button(group.isCollapsed ? "Expand Group" : "Collapse Group") { model.toggleCollapsed(group.id) }
            Divider()
            Button("New Tab in Group") { model.newTab(inGroup: group.id) }
            Divider()
            Button("Ungroup Tabs") { model.ungroup(group.id) }
            Button("Close Group") { model.closeGroup(group.id) }
        }
    }

    @ViewBuilder
    private var pill: some View {
        if state.groupLabelStyle == .firefox {
            Text(group.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 12)
                .frame(minWidth: 30, minHeight: 28)
                .background(
                    UnevenRoundedRectangle(cornerRadii: .init(topLeading: 14, bottomLeading: 3, bottomTrailing: 14, topTrailing: 14))
                        .fill(Color(nsColor: Self.light(color))))
        } else {
            solidPill
        }
    }

    private var solidPill: some View {
        HStack(spacing: 4) {
            if !group.name.isEmpty {
                Text(group.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
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
        .frame(minWidth: 26, minHeight: 22)
        .background(Capsule().fill(Color(nsColor: color)))
    }

    /// Firefox's label color: the group color lightened toward white.
    static func light(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB)?.blended(withFraction: 0.25, of: .white) ?? color
    }
}

/// Firefox's group panel: the name, a row of colors and the group's actions.
/// It opens on a new group (Done keeps it, Cancel ungroups the tab again) and
/// from "Edit Group…".
struct TabGroupEditor: View {
    let groupID: UUID
    let isNew: Bool
    let model: TabSidebarModel
    @ObservedObject private var store = TabGroupStore.shared
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private static let colors = TerminalTabColor.allCases.filter { $0 != .none }

    var body: some View {
        let group = store.group(groupID)
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Create Tab Group" : "Manage Tab Group")
                .font(.system(size: 13, weight: .semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onChange(of: name) { newName in
                    store.update(groupID) { $0.name = newName.trimmingCharacters(in: .whitespaces) }
                }
                .onSubmit { model.endEditingGroup() }

            HStack(spacing: 6) {
                ForEach(Self.colors, id: \.self) { color in
                    let selected = group?.color == color
                    Circle()
                        .fill(Color(nsColor: color.displayColor ?? .systemGray))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.7 : 0), lineWidth: 2))
                        .contentShape(Circle())
                        .onTapGesture { store.update(groupID) { $0.color = color } }
                        .help(color.localizedName)
                }
            }

            if isNew {
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelNewGroup(groupID) }
                    Button("Done") { model.endEditingGroup() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    action("New Tab in Group", "plus") { model.newTab(inGroup: groupID) }
                    action("Ungroup Tabs", "rectangle.stack.badge.minus") { model.ungroup(groupID) }
                    action("Close Group", "xmark.rectangle") { model.closeGroup(groupID) }
                }
            }
        }
        .padding(14)
        // Wide enough for the row of colors: 9 × 24pt, 6pt apart, plus padding.
        .frame(width: 300)
        .onAppear {
            name = group?.name ?? ""
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    private func action(_ title: String, _ icon: String, perform: @escaping () -> Void) -> some View {
        Button {
            model.endEditingGroup()
            perform()
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Button(group.name.isEmpty ? "Unnamed Group" : group.name) { model.addTab(tab.id, toGroup: group.id) }
            }
        }
        if tab.groupID != nil {
            Button("Remove from Group") { model.addTab(tab.id, toGroup: nil) }
        }
    }
}
