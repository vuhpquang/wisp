import AppKit
import Combine

/// A tab that was unloaded to free its shell and memory. It keeps what's
/// needed to open it again: splits, working directories, title and color.
/// Scrollback is not kept.
struct SleepingTab: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var directory: String?
    var workspaceID: UUID
    var tab: TabLayout.Tab
    var sleptAt = Date()
}

/// Sleeping tabs and the automatic unloading of idle tabs.
final class TabSleepStore: ObservableObject {
    static let shared = TabSleepStore()

    private static let tabsKey = "TabSleepingTabs"
    private static let autoKey = "TabAutoUnloadMinutes"

    /// Minutes a tab may stay unviewed before it is unloaded. 0 means tabs are
    /// only unloaded from the tab menu.
    static let autoUnloadChoices = [0, 15, 30, 60, 120, 240]

    @Published private(set) var tabs: [SleepingTab] {
        didSet { save() }
    }

    @Published var autoUnloadMinutes: Int {
        didSet { UserDefaults.ghostty.set(autoUnloadMinutes, forKey: Self.autoKey) }
    }

    private var timer: Timer?

    private init() {
        tabs = UserDefaults.ghostty.data(forKey: Self.tabsKey)
            .flatMap { try? JSONDecoder().decode([SleepingTab].self, from: $0) } ?? []
        autoUnloadMinutes = UserDefaults.ghostty.object(forKey: Self.autoKey) as? Int ?? 0
    }

    func startAutoUnload() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.unloadIdleTabs()
        }
    }

    // MARK: Unloading

    enum UnloadError: LocalizedError {
        case running
        case lastTab

        var errorDescription: String? {
            switch self {
            case .running: "This tab is running a program. Quit it before unloading the tab."
            case .lastTab: "The last open tab of a window can't be unloaded."
            }
        }
    }

    /// Whether a tab could be unloaded without losing a running program.
    static func canUnload(_ window: NSWindow) -> Result<Void, UnloadError> {
        guard let controller = window.windowController as? TerminalController else { return .failure(.running) }
        let others = window.tabGroup?.windows.filter { $0 !== window } ?? []
        guard !others.isEmpty else { return .failure(.lastTab) }

        let running = controller.surfaceTree.contains { surface in
            if surface.needsConfirmQuit { return true }
            if case .running = TabCommandTracker.shared.state(of: surface) { return true }
            return false
        }
        return running ? .failure(.running) : .success(())
    }

    /// Close a tab and keep it as a sleeping tab.
    func unload(_ window: NSWindow) throws {
        if case .failure(let error) = Self.canUnload(window) { throw error }
        guard let controller = window.windowController as? TerminalController,
              let tab = TabSidebarModel.layoutTab(of: window) else { throw UnloadError.running }

        // Leave the tab selected next to it rather than whatever AppKit picks.
        if window.tabGroup?.selectedWindow === window,
           let windows = window.tabGroup?.windows,
           let index = windows.firstIndex(of: window) {
            let next = index + 1 < windows.count ? windows[index + 1] : windows[index - 1]
            window.tabGroup?.selectedWindow = next
            next.makeKeyAndOrderFront(nil)
        }

        let directory = controller.focusedSurface?.pwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
        tabs.append(SleepingTab(
            title: window.title.isEmpty ? "👻" : window.title,
            directory: directory,
            workspaceID: TabWorkspaceStore.shared.workspaceID(of: window),
            tab: tab))
        controller.closeTab(nil)
    }

    /// Open a sleeping tab again next to `parent` and select it.
    func wake(_ id: SleepingTab.ID, from parent: NSWindow) {
        guard let sleeping = tabs.first(where: { $0.id == id }),
              let ghostty = (parent.windowController as? BaseTerminalController)?.ghostty else { return }

        TabWorkspaceStore.shared.activate(sleeping.workspaceID)
        tabs.removeAll { $0.id == id }
        guard let controller = TabSidebarModel.openTab(sleeping.tab, from: parent, ghostty: ghostty) else { return }
        (controller.window as? TerminalWindow)?.workspaceID = sleeping.workspaceID
    }

    func remove(_ id: SleepingTab.ID) {
        tabs.removeAll { $0.id == id }
    }

    /// Move sleeping tabs to another workspace, e.g. when theirs is deleted.
    func reassign(from workspaceID: UUID, to newID: UUID) {
        for index in tabs.indices where tabs[index].workspaceID == workspaceID {
            tabs[index].workspaceID = newID
        }
    }

    /// Unload tabs that weren't viewed for longer than the configured time and
    /// aren't running anything. Pinned tabs and selected tabs stay.
    private func unloadIdleTabs() {
        guard autoUnloadMinutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(autoUnloadMinutes) * 60)

        for controller in TerminalController.all {
            guard let window = controller.window as? TerminalWindow,
                  window.usesVerticalTabs,
                  !window.isTabPinned,
                  window.tabGroup?.selectedWindow !== window,
                  window.lastViewedAt < cutoff,
                  case .success = Self.canUnload(window) else { continue }
            try? unload(window)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        UserDefaults.ghostty.set(data, forKey: Self.tabsKey)
    }
}
