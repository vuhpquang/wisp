import AppKit
import Combine

/// A named group of tabs. Only the tabs of the active workspace (plus pinned
/// tabs, which belong to every workspace) are shown in the sidebar and reached
/// by tab navigation.
struct TabWorkspace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var icon: String
}

/// App-wide list of workspaces and which one is active.
final class TabWorkspaceStore: ObservableObject {
    static let shared = TabWorkspaceStore()

    private static let workspacesKey = "TabWorkspaces"
    private static let activeKey = "TabWorkspaceActive"

    @Published private(set) var workspaces: [TabWorkspace] {
        didSet { save() }
    }

    @Published private(set) var activeID: UUID {
        didSet { UserDefaults.ghostty.set(activeID.uuidString, forKey: Self.activeKey) }
    }

    /// The last selected tab of each workspace, so switching back returns to it.
    private var lastSelected: [UUID: Weak<NSWindow>] = [:]

    private var keyObserver: NSObjectProtocol?

    private init() {
        let saved = UserDefaults.ghostty.data(forKey: Self.workspacesKey)
            .flatMap { try? JSONDecoder().decode([TabWorkspace].self, from: $0) } ?? []
        let workspaces = saved.isEmpty
            ? [TabWorkspace(id: UUID(), name: "Default", icon: "🏠")]
            : saved
        self.workspaces = workspaces

        let savedActive = UserDefaults.ghostty.string(forKey: Self.activeKey).flatMap(UUID.init)
        activeID = workspaces.first { $0.id == savedActive }?.id ?? workspaces[0].id

        // Selecting a tab makes its workspace active, whichever way it was selected.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] n in
            guard let self, let window = n.object as? TerminalWindow,
                  window.usesVerticalTabs, !window.isTabPinned else { return }
            let id = self.workspaceID(of: window)
            self.lastSelected[id] = .init(window)
            if self.activeID != id { self.activeID = id }
        }
    }

    var active: TabWorkspace {
        workspaces.first { $0.id == activeID } ?? workspaces[0]
    }

    /// The workspace a window belongs to. Windows without one, or whose
    /// workspace was deleted, belong to the first workspace.
    func workspaceID(of window: NSWindow) -> UUID {
        guard let id = (window as? TerminalWindow)?.workspaceID,
              workspaces.contains(where: { $0.id == id }) else { return workspaces[0].id }
        return id
    }

    /// The tabs that tab navigation (goto_tab, next_tab, ...) cycles through:
    /// pinned tabs followed by the tabs of the active workspace.
    func navigableWindows(_ windows: [NSWindow]) -> [NSWindow] {
        guard windows.contains(where: { ($0 as? TerminalWindow)?.usesVerticalTabs == true }) else {
            return windows
        }

        return windows.filter { window in
            (window as? TerminalWindow)?.isTabPinned == true || workspaceID(of: window) == activeID
        }
    }

    func lastSelectedWindow(in id: UUID) -> NSWindow? {
        lastSelected[id]?.value
    }

    // MARK: Editing

    func activate(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        activeID = id
    }

    @discardableResult
    func create(name: String, icon: String) -> TabWorkspace {
        let workspace = TabWorkspace(id: UUID(), name: name, icon: icon)
        workspaces.append(workspace)
        return workspace
    }

    func update(_ id: UUID, name: String, icon: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].name = name
        workspaces[index].icon = icon
    }

    /// Delete a workspace. Its tabs move to the first remaining workspace.
    func delete(_ id: UUID) {
        guard workspaces.count > 1 else { return }
        workspaces.removeAll { $0.id == id }
        if activeID == id { activeID = workspaces[0].id }
        NotificationCenter.default.post(name: TabSidebarState.tabsDidChange, object: nil)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.ghostty.set(data, forKey: Self.workspacesKey)
    }
}

// MARK: - Layouts

/// A saved set of tabs that can be reopened as a workspace. Layouts are kept
/// in a JSON file so they can be edited by hand, e.g. to add a command to run.
struct TabLayout: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var icon: String?
    var tabs: [Tab]

    struct Tab: Codable, Equatable {
        /// The tab title. Leave empty to use the title set by the terminal.
        var title: String?

        /// The working directory. `~` is expanded.
        var cwd: String?

        /// Typed into the shell when the tab opens, e.g. `npm run dev`.
        var run: String?

        /// A tab color name such as `blue` or `green`.
        var color: String?

        /// Splits inside the tab. When set, `cwd` and `run` are ignored and
        /// each pane has its own.
        var split: Split?

        /// The root pane of the tab.
        var rootPane: Pane {
            Pane(cwd: cwd, run: run, split: split)
        }
    }

    /// One terminal in a tab, or a split of two more panes.
    struct Pane: Codable, Equatable {
        var cwd: String?
        var run: String?
        var split: Split?

        /// The pane that keeps the original terminal when this pane is split:
        /// the first pane, recursively.
        var leading: Pane {
            split?.panes.first?.leading ?? self
        }

        var surfaceConfiguration: Ghostty.SurfaceConfiguration {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = cwd.map { ($0 as NSString).expandingTildeInPath }
            if let run, !run.isEmpty { config.initialInput = run + "\n" }
            return config
        }
    }

    struct Split: Codable, Equatable {
        /// `right` puts the panes side by side, `down` stacks them.
        var direction: String

        /// Exactly two panes.
        var panes: [Pane]
    }
}

enum TabLayoutStore {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/tab-layouts.json")
    }

    static func load() -> [TabLayout] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([TabLayout].self, from: data)
        } catch {
            Ghostty.logger.warning("failed to parse tab layouts: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Add a layout, replacing any layout with the same name.
    static func save(_ layout: TabLayout) throws {
        var layouts = load().filter { $0.name != layout.name }
        layouts.append(layout)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(layouts)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Create the file with an example layout if it doesn't exist, then open it.
    static func openFile() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? save(TabLayout(name: "Example", icon: "🧪", tabs: [
                .init(title: "Home", cwd: "~", run: nil, color: "blue"),
                .init(title: "Split", color: "green", split: .init(direction: "right", panes: [
                    .init(cwd: "~", run: "ls"),
                    .init(split: .init(direction: "down", panes: [
                        .init(cwd: "~/Downloads"),
                        .init(cwd: "~/Desktop"),
                    ])),
                ])),
            ]))
        }
        NSWorkspace.shared.open(fileURL)
    }
}

extension TerminalTabColor {
    /// Look up a color by its name, ignoring case.
    init?(name: String) {
        guard let color = Self.allCases.first(where: {
            $0.localizedName.caseInsensitiveCompare(name) == .orderedSame
        }) else { return nil }
        self = color
    }
}
