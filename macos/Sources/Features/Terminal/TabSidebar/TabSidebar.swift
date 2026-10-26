import AppKit
import Combine
import SwiftUI

/// App-wide state for the vertical tab sidebar. The pinned state is shared by
/// every window so switching tabs (which are separate NSWindows) keeps the
/// sidebar in the same place.
final class TabSidebarState: ObservableObject {
    static let shared = TabSidebarState()

    /// Posted whenever something shown in the sidebar may have changed: tab
    /// order, titles, colors, selection.
    static let tabsDidChange = Notification.Name("com.mitchellh.ghostty.tabSidebarTabsDidChange")

    static let defaultWidth: CGFloat = 220
    static let widthRange: ClosedRange<CGFloat> = 150...420

    /// Height of the floating sidebar shown while collapsed, as a fraction of
    /// the window height. It is centered vertically.
    static let floatingHeightFraction: CGFloat = 0.75

    /// How close to the left edge of the window the mouse has to be to reveal
    /// a collapsed sidebar.
    private static let revealEdge: CGFloat = 6

    private static let pinnedKey = "TabSidebarPinned"
    private static let detailsKey = "TabSidebarShowsDetails"
    private static let previewKey = "TabSidebarShowsPreview"
    private static let groupStyleKey = "TabSidebarGroupLabelStyle"
    private static let colorStyleKey = "TabSidebarColorStyle"

    /// Show each tab's folder, git branch and command time under its title.
    @Published var showsDetails: Bool {
        didSet { UserDefaults.ghostty.set(showsDetails, forKey: Self.detailsKey) }
    }

    /// Show a tab's visible text when hovering it.
    @Published var showsPreview: Bool {
        didSet { UserDefaults.ghostty.set(showsPreview, forKey: Self.previewKey) }
    }

    /// How tab group labels look.
    @Published var groupLabelStyle: TabGroupLabelStyle {
        didSet { UserDefaults.ghostty.set(groupLabelStyle.rawValue, forKey: Self.groupStyleKey) }
    }

    /// Whether colored tabs are filled with their color or marked with a dot.
    @Published var colorStyle: TabColorStyle {
        didSet {
            UserDefaults.ghostty.set(colorStyle.rawValue, forKey: Self.colorStyleKey)
            // The horizontal tab bar paints its own tint.
            for window in NSApp.windows {
                (window as? TerminalWindow)?.updateTabBackgroundTint()
            }
        }
    }
    private static let widthKey = "TabSidebarWidth"

    /// Whether the sidebar takes up space next to the terminal. When false the
    /// sidebar is collapsed and floats over the terminal on hover.
    @Published var isPinned: Bool {
        didSet { UserDefaults.ghostty.set(isPinned, forKey: Self.pinnedKey) }
    }

    /// The sidebar width, resized by dragging its trailing edge.
    @Published var width: CGFloat {
        didSet { UserDefaults.ghostty.set(Double(width), forKey: Self.widthKey) }
    }

    /// Whether a collapsed sidebar is temporarily shown because the mouse is
    /// at the left edge of the window.
    @Published private(set) var isRevealed = false

    /// Vertical tabs, or the native horizontal tab bar. Follows the
    /// `macos-vertical-tabs` option and can be switched from the tab menu.
    @Published private(set) var isEnabled: Bool

    private var configObserver: NSObjectProtocol?

    private var mouseMonitor: Any?

    private init() {
        isEnabled = (NSApp.delegate as? AppDelegate)?.ghostty.config.macosVerticalTabs ?? true
        isPinned = UserDefaults.ghostty.object(forKey: Self.pinnedKey) as? Bool ?? true
        showsDetails = UserDefaults.ghostty.object(forKey: Self.detailsKey) as? Bool ?? true
        showsPreview = UserDefaults.ghostty.object(forKey: Self.previewKey) as? Bool ?? true
        groupLabelStyle = UserDefaults.ghostty.string(forKey: Self.groupStyleKey)
            .flatMap(TabGroupLabelStyle.init(rawValue:)) ?? .firefox
        colorStyle = UserDefaults.ghostty.string(forKey: Self.colorStyleKey)
            .flatMap(TabColorStyle.init(rawValue:)) ?? .fill
        let savedWidth = (UserDefaults.ghostty.object(forKey: Self.widthKey) as? Double).map { CGFloat($0) }
        width = Self.clampWidth(savedWidth ?? Self.defaultWidth)

        // Editing the option in Settings or the config file switches live.
        configObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] n in
            guard n.object == nil,
                  let config = n.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config else { return }
            self?.apply(enabled: config.macosVerticalTabs)
        }
    }

    /// Switch between vertical and horizontal tabs and remember the choice.
    func setEnabled(_ enabled: Bool) {
        apply(enabled: enabled)
        WispSettings.shared.set("macos-vertical-tabs", enabled ? "true" : "false")
    }

    private func apply(enabled: Bool) {
        guard enabled != isEnabled else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isEnabled = enabled
            isRevealed = false
        }

        // Workspaces only scope tab numbers while the sidebar shows them.
        DispatchQueue.main.async {
            TerminalController.all.forEach { $0.relabelTabs() }
        }
    }

    static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    /// Toggle between pinned and collapsed. Returns false if no window uses
    /// vertical tabs so the keybinding can fall through.
    func togglePinned() -> Bool {
        guard NSApp.windows.contains(where: { ($0 as? TerminalWindow)?.usesVerticalTabs == true }) else {
            return false
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            isPinned.toggle()
            isRevealed = false
        }
        return true
    }

    func installMouseMonitorIfNeeded() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            self?.handleMouse(event)
            return event
        }
    }

    /// Show a collapsed sidebar while its search field has focus (⌘L), even
    /// if the mouse is away from it.
    var keepsRevealed = false {
        didSet {
            guard !isPinned, keepsRevealed != oldValue else { return }
            withAnimation(.easeOut(duration: 0.15)) { isRevealed = keepsRevealed }
        }
    }

    private func handleMouse(_ event: NSEvent) {
        guard !isPinned, !keepsRevealed else { return }
        guard let window = event.window as? TerminalWindow, window.usesVerticalTabs else { return }

        let x = event.locationInWindow.x
        if !isRevealed, x <= Self.revealEdge {
            withAnimation(.easeOut(duration: 0.15)) { isRevealed = true }
        } else if isRevealed, x > width + 32 {
            withAnimation(.easeIn(duration: 0.15)) { isRevealed = false }
        }
    }
}

extension Notification.Name {
    /// A surface's progress report (OSC 9;4) was set or cleared.
    static let ghosttySurfaceProgressDidChange = Notification.Name("com.mitchellh.ghostty.surfaceProgressDidChange")
}

/// The tabs of a single tab group, as shown by the sidebar of one window.
final class TabSidebarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let color: TerminalTabColor
        let isSelected: Bool
        let keyEquivalent: String
        let hasBell: Bool
        let isPinned: Bool
        let workspaceID: UUID
        let activity: Activity

        /// The working directory of the focused split, abbreviated with `~`.
        let directory: String?
        let branch: String?
        let command: TabCommandState?

        /// Rang the bell, reported an error or finished a long command since
        /// the user last looked at it.
        let needsAttention: Bool

        /// The sidebar tab group, if the tab is in one that still exists.
        let groupID: UUID?
    }

    /// A row of the workspace's tab list: a tab, or a group's label.
    enum Item: Identifiable {
        case tab(Tab)
        case group(TabGroup, count: Int)

        var id: String {
            switch self {
            case .tab(let tab): "tab-\(tab.id.hashValue)"
            case .group(let group, _): "group-\(group.id)"
            }
        }
    }

    /// What the programs in a tab report through progress reports (OSC 9;4).
    /// Agents such as Claude Code report progress while they work.
    enum Activity: Equatable {
        case idle
        case busy
        case progress(Double)
        case error
    }

    @Published private(set) var tabs: [Tab] = []

    var pinnedTabs: [Tab] { tabs.filter(\.isPinned) }

    /// The unpinned tabs of the active workspace.
    var workspaceTabs: [Tab] {
        let active = TabWorkspaceStore.shared.activeID
        return tabs.filter { !$0.isPinned && $0.workspaceID == active }
    }

    /// Tabs needing attention that aren't visible in the list: those in other
    /// workspaces.
    var hiddenAttentionTabs: [Tab] {
        let active = TabWorkspaceStore.shared.activeID
        return tabs.filter { $0.needsAttention && !$0.isPinned && $0.workspaceID != active }
    }

    func needsAttention(in id: UUID) -> Bool {
        tabs.contains { $0.needsAttention && !$0.isPinned && $0.workspaceID == id }
    }

    /// Tabs per workspace, used to show which workspaces are empty.
    func tabCount(in id: UUID) -> Int {
        tabs.filter { !$0.isPinned && $0.workspaceID == id }.count
    }

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var reloadScheduled = false

    init(window: NSWindow) {
        self.window = window

        let center = NotificationCenter.default

        // Tab changes the user caused: reload on the next loop iteration so
        // selection feels instant.
        let tabEvents: [Notification.Name] = [
            TabSidebarState.tabsDidChange,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
        ]
        for name in tabEvents {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleReload(after: 0)
            })
        }

        // Events from the terminals arrive in bursts (a command finishing changes
        // the pwd, progress and command state at once), so wait a little.
        let surfaceEvents: [Notification.Name] = [
            .terminalWindowBellDidChangeNotification,
            .ghosttySurfaceProgressDidChange,
            .ghosttySurfacePwdDidChange,
            .tabCommandStateDidChange,
        ]
        for name in surfaceEvents {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleReload(after: Self.surfaceEventDelay)
            })
        }

        // Workspace changes alter which tabs are shown and numbered.
        let store = TabWorkspaceStore.shared
        store.$activeID.removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                self?.clearSelection()
                self?.scheduleReload(after: 0)
                DispatchQueue.main.async {
                    (self?.window?.tabGroup?.selectedWindow?.windowController as? TerminalController)?.relabelTabs()
                }
            }
            .store(in: &cancellables)
        store.$workspaces.dropFirst()
            .sink { [weak self] _ in self?.scheduleReload(after: 0) }
            .store(in: &cancellables)
        // Collapsing, renaming or recoloring a group changes no tab, so the
        // reload alone publishes nothing: redraw explicitly.
        TabGroupStore.shared.$groups.dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.scheduleReload(after: 0)
            }
            .store(in: &cancellables)

        TabSidebarState.shared.installMouseMonitorIfNeeded()
        TabSleepStore.shared.startAutoUnload()
        reload()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private static let surfaceEventDelay: TimeInterval = 0.05

    /// Every tab is a window with its own sidebar, but only the selected tab's
    /// sidebar is on screen. The others skip reloads until they are shown.
    private var isOnScreen: Bool {
        guard let window else { return false }
        return (window.tabGroup?.selectedWindow ?? window) === window
    }

    /// Coalesce bursts of notifications into one reload, after AppKit has
    /// settled the tab group. Hidden sidebars reload when they're shown: their
    /// window becoming key triggers a reload.
    private func scheduleReload(after delay: TimeInterval) {
        guard isOnScreen, !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            if self.isOnScreen { self.reload() }
        }
    }

    private func reload() {
        let windows = tabWindows
        let selected = window?.tabGroup?.selectedWindow ?? window
        let newTabs = windows.map { w in
            let terminal = w as? TerminalWindow
            let surface = (w.windowController as? BaseTerminalController)?.focusedSurface
            let pwd = surface?.pwd.flatMap { $0.isEmpty ? nil : $0 }
            let hasBell = (w.windowController as? BaseTerminalController)?.bell ?? false
            let activity = Self.activity(of: w)
            let isSelected = w === selected
            return Tab(
                id: ObjectIdentifier(w),
                title: w.title.isEmpty ? "👻" : w.title,
                color: terminal?.tabColor ?? .none,
                isSelected: isSelected,
                keyEquivalent: terminal?.keyEquivalent ?? "",
                hasBell: hasBell,
                isPinned: terminal?.isTabPinned ?? false,
                workspaceID: TabWorkspaceStore.shared.workspaceID(of: w),
                activity: activity,
                directory: pwd.map { ($0 as NSString).abbreviatingWithTildeInPath },
                branch: pwd.flatMap(TabGitInfo.branch(at:)),
                command: surface.flatMap(TabCommandTracker.shared.state(of:)),
                needsAttention: !isSelected && (hasBell || activity == .error || Self.finishedUnseen(w)),
                groupID: TabGroupStore.shared.group(terminal?.tabGroupID)?.id)
        }

        // Views read the active workspace from the store directly, so only
        // publish when the tabs themselves changed.
        if newTabs != tabs { tabs = newTabs }

        // Forget closed tabs.
        let ids = Set(newTabs.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
    }

    /// Whether a long command finished in any split since the tab was viewed.
    private static func finishedUnseen(_ window: NSWindow) -> Bool {
        guard let terminal = window as? TerminalWindow,
              let controller = window.windowController as? BaseTerminalController else { return false }
        return controller.surfaceTree.contains { surface in
            guard case .finished(let at, _, let duration) = TabCommandTracker.shared.state(of: surface) else {
                return false
            }
            return duration >= 5 && at > terminal.lastViewedAt
        }
    }

    private static func activity(of window: NSWindow) -> Activity {
        guard let controller = window.windowController as? BaseTerminalController else { return .idle }
        let reports = controller.surfaceTree.compactMap(\.progressReport)
        if reports.contains(where: { $0.state == .error }) { return .error }
        if let report = reports.first(where: { $0.state == .set }), let value = report.progress {
            return .progress(Double(value) / 100)
        }
        if reports.contains(where: { $0.state != .remove }) { return .busy }
        return .idle
    }

    private var tabWindows: [NSWindow] {
        guard let window else { return [] }
        return window.tabGroup?.windows ?? [window]
    }

    private func window(for id: Tab.ID) -> NSWindow? {
        tabWindows.first { ObjectIdentifier($0) == id }
    }

    // MARK: Actions

    func select(_ id: Tab.ID) {
        guard let target = window(for: id) else { return }
        target.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(nil)

        // Give the terminal focus back, e.g. after typing in the search field.
        if let surface = (target.windowController as? BaseTerminalController)?.focusedSurface {
            target.makeFirstResponder(surface)
        }
    }

    // MARK: Selecting several tabs

    /// Tabs picked with ⌘- or ⇧-click to close, group or move together. The
    /// selected (shown) tab doesn't change while picking them.
    @Published private(set) var selection: Set<Tab.ID> = []

    /// Where a ⇧-click range starts: the last ⌘-clicked tab, else the shown one.
    private var selectionAnchor: Tab.ID?

    func isMultiSelected(_ id: Tab.ID) -> Bool {
        selection.count > 1 && selection.contains(id)
    }

    /// The picked tabs in tab order.
    var selectedIDs: [Tab.ID] {
        tabs.map(\.id).filter(selection.contains)
    }

    /// A click on a tab: ⌘ adds or removes it, ⇧ picks every tab between it and
    /// the anchor, a plain click shows it and forgets the picked tabs.
    func click(_ id: Tab.ID) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shown = tabs.first(where: \.isSelected)?.id

        if flags.contains(.shift) {
            let anchor = selectionAnchor ?? shown ?? id
            let order = visibleTabIDs
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
                let range = Set(order[min(a, b)...max(a, b)])
                selection = flags.contains(.command) ? selection.union(range) : range
            } else {
                selection.insert(id)
            }
            selectionAnchor = anchor
        } else if flags.contains(.command) {
            if selection.isEmpty, let shown { selection.insert(shown) }
            if selection.remove(id) == nil { selection.insert(id) }
            selectionAnchor = id
        } else {
            clearSelection()
            select(id)
        }
    }

    func clearSelection() {
        if !selection.isEmpty { selection = [] }
        selectionAnchor = nil
    }

    /// Tabs in the order the sidebar lists them: pinned tiles, then the list.
    private var visibleTabIDs: [Tab.ID] {
        pinnedTabs.map(\.id) + workspaceItems.compactMap { item in
            if case .tab(let tab) = item { return tab.id }
            return nil
        }
    }

    /// The visible text of a tab's focused split, without trailing blank lines.
    func previewText(for id: Tab.ID, maxLines: Int = 24) -> String? {
        guard let surface = (window(for: id)?.windowController as? BaseTerminalController)?.focusedSurface else {
            return nil
        }

        var lines = surface.cachedVisibleContents.get()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Tabs in any workspace whose title, folder or branch contains the query.
    func search(_ query: String) -> [Tab] {
        let words = query.lowercased().split(separator: " ")
        return tabs.filter { tab in
            let haystack = [tab.title, tab.directory ?? "", tab.branch ?? ""]
                .joined(separator: " ")
                .lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    func close(_ id: Tab.ID) {
        guard let controller = window(for: id)?.windowController as? TerminalController else { return }
        controller.closeTab(nil)
    }

    func closeOthers(_ id: Tab.ID) {
        select(id)
        (window(for: id)?.windowController as? TerminalController)?.closeOtherTabs(nil)
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    /// The tab being renamed in place, set by double-clicking it or from its
    /// menu. The row shows a text field while it's set.
    @Published var renamingID: Tab.ID?

    func rename(_ id: Tab.ID) {
        renamingID = id
    }

    /// The text to start renaming with: the custom title, else the terminal's.
    func editableTitle(_ id: Tab.ID) -> String {
        guard let window = window(for: id) else { return "" }
        return (window.windowController as? BaseTerminalController)?.titleOverride ?? window.title
    }

    /// Set a tab's title. An empty title goes back to the terminal's own.
    func finishRenaming(_ id: Tab.ID, title: String?) {
        renamingID = nil
        defer { select(id) } // also gives the terminal its focus back
        guard let title,
              let controller = window(for: id)?.windowController as? BaseTerminalController else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        controller.titleOverride = trimmed.isEmpty ? nil : trimmed
    }

    func setColor(_ color: TerminalTabColor, for id: Tab.ID) {
        (window(for: id) as? TerminalWindow)?.tabColor = color
    }

    // MARK: Tab groups

    /// The workspace's tabs with each group's label before its tabs. A group's
    /// tabs are listed together where its first tab is. A collapsed group only
    /// shows its selected tab.
    var workspaceItems: [Item] {
        let tabs = workspaceTabs
        let store = TabGroupStore.shared
        var items: [Item] = []
        var listed = Set<UUID>()

        for tab in tabs {
            guard let groupID = tab.groupID, let group = store.group(groupID) else {
                items.append(.tab(tab))
                continue
            }
            guard listed.insert(groupID).inserted else { continue }

            let members = tabs.filter { $0.groupID == groupID }
            items.append(.group(group, count: members.count))
            for member in members where !group.isCollapsed || member.isSelected {
                items.append(.tab(member))
            }
        }
        return items
    }

    /// Groups with tabs in the active workspace, in sidebar order.
    var visibleGroups: [TabGroup] {
        workspaceItems.compactMap { item in
            if case .group(let group, _) = item { return group }
            return nil
        }
    }

    func toggleCollapsed(_ groupID: UUID) {
        withAnimation(.easeInOut(duration: 0.22)) {
            TabGroupStore.shared.update(groupID) { $0.isCollapsed.toggle() }
        }
    }

    /// Put a tab in a group (nil removes it from its group). It moves next to
    /// the group's other tabs.
    func addTab(_ id: Tab.ID, toGroup groupID: UUID?) {
        guard let window = window(for: id) as? TerminalWindow else { return }
        let previous = window.tabGroupID
        window.tabGroupID = groupID
        if let groupID { moveNextToGroup(window, groupID: groupID) }
        if let previous { deleteGroupIfEmpty(previous) }
    }

    /// The group whose panel is open, and whether it was just created.
    struct EditingGroup: Equatable {
        let id: UUID
        let isNew: Bool
    }

    @Published private(set) var editingGroup: EditingGroup?

    /// Like Firefox: the tab joins a new group right away and the group's panel
    /// opens to name it and pick a color.
    func promptNewGroup(with tabID: Tab.ID) {
        promptNewGroup(with: [tabID])
    }

    /// The tabs gather where the first one is.
    func promptNewGroup(with tabIDs: [Tab.ID]) {
        guard !tabIDs.isEmpty else { return }
        let group = TabGroupStore.shared.create(name: "")
        for id in tabIDs { addTab(id, toGroup: group.id) }
        // Let the label appear before the panel anchors to it.
        DispatchQueue.main.async { [weak self] in self?.editingGroup = EditingGroup(id: group.id, isNew: true) }
    }

    func editGroup(_ groupID: UUID) {
        editingGroup = EditingGroup(id: groupID, isNew: false)
    }

    func endEditingGroup() {
        editingGroup = nil
    }

    /// Cancel on a new group's panel: the tab leaves it and the group goes away.
    func cancelNewGroup(_ groupID: UUID) {
        editingGroup = nil
        ungroup(groupID)
    }

    /// Keep the tabs, forget the group.
    func ungroup(_ groupID: UUID) {
        for window in members(of: groupID) { window.tabGroupID = nil }
        TabGroupStore.shared.delete(groupID)
    }

    /// Close every tab in the group. Tabs running a program ask first.
    func closeGroup(_ groupID: UUID) {
        for window in members(of: groupID) {
            (window.windowController as? TerminalController)?.closeTab(nil)
        }
        DispatchQueue.main.async { [weak self] in self?.deleteGroupIfEmpty(groupID) }
    }

    func newTab(inGroup groupID: UUID) {
        guard let parent = window,
              let ghostty = (parent.windowController as? BaseTerminalController)?.ghostty,
              let controller = TerminalController.newTab(ghostty, from: parent),
              let window = controller.window as? TerminalWindow else { return }
        window.tabGroupID = groupID
        moveNextToGroup(window, groupID: groupID)
        TabGroupStore.shared.update(groupID) { $0.isCollapsed = false }
    }

    private func members(of groupID: UUID) -> [TerminalWindow] {
        tabWindows.compactMap { $0 as? TerminalWindow }.filter { $0.tabGroupID == groupID }
    }

    private func moveNextToGroup(_ window: NSWindow, groupID: UUID) {
        guard let last = members(of: groupID).last(where: { $0 !== window }) else { return }
        reorder(window, relativeTo: last, ordered: .above)
    }

    private func deleteGroupIfEmpty(_ groupID: UUID) {
        if members(of: groupID).isEmpty { TabGroupStore.shared.delete(groupID) }
    }

    // MARK: Sleeping tabs

    /// Unloaded tabs of the active workspace.
    var sleepingTabs: [SleepingTab] {
        let active = TabWorkspaceStore.shared.activeID
        return TabSleepStore.shared.tabs.filter { $0.workspaceID == active }
    }

    func unload(_ id: Tab.ID) {
        guard let target = window(for: id) else { return }
        do {
            try TabSleepStore.shared.unload(target)
        } catch {
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = "Can't Unload Tab"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }

    /// Open a sleeping tab where it was: back in its group if that still has
    /// tabs, at its old position.
    func wake(_ id: SleepingTab.ID) {
        guard let window,
              let sleeping = TabSleepStore.shared.tabs.first(where: { $0.id == id }),
              let woken = TabSleepStore.shared.wake(id, from: window)?.window as? TerminalWindow else { return }

        if let groupID = sleeping.groupID, !members(of: groupID).isEmpty {
            woken.tabGroupID = groupID
        }

        let others = tabWindows.filter { $0 !== woken }
        if let position = sleeping.position, !others.isEmpty {
            if position < others.count {
                reorder(woken, relativeTo: others[position], ordered: .below)
            } else if let last = others.last {
                reorder(woken, relativeTo: last, ordered: .above)
            }
        }

        // Its old neighbors may have moved; it must at least sit with its group.
        if let groupID = woken.tabGroupID {
            let windows = tabWindows
            if let index = windows.firstIndex(of: woken),
               ![index - 1, index + 1].contains(where: { windows.indices.contains($0) && (windows[$0] as? TerminalWindow)?.tabGroupID == groupID }) {
                moveNextToGroup(woken, groupID: groupID)
            }
        }
    }

    // MARK: Search

    /// Bumped to move keyboard focus to the search field.
    @Published private(set) var searchFocusRequest = 0

    /// Focus the search field (⌘L). Returns false without a sidebar so the
    /// keybinding can fall through.
    func focusSearch() -> Bool {
        guard (window as? TerminalWindow)?.usesVerticalTabs == true else { return false }
        searchFocusRequest += 1
        return true
    }

    /// Give the shown tab's terminal focus back, e.g. on Escape in the search.
    func focusTerminal() {
        guard let shown = tabs.first(where: \.isSelected) ?? tabs.first else { return }
        select(shown.id)
    }

    // MARK: Attention

    /// Select the next tab needing attention after the selected one, in any
    /// workspace. Returns false if there is none.
    @discardableResult
    func gotoNextAttentionTab() -> Bool {
        reload()
        let selectedIndex = tabs.firstIndex(where: \.isSelected) ?? -1
        let ordered = tabs[(selectedIndex + 1)...] + tabs[..<max(selectedIndex + 1, 0)]
        guard let tab = ordered.first(where: \.needsAttention) else { return false }

        if !tab.isPinned { TabWorkspaceStore.shared.activate(tab.workspaceID) }
        select(tab.id)
        return true
    }

    // MARK: Workspaces

    /// Make a workspace active and select its last used tab, opening a new tab
    /// if the workspace has none.
    func switchWorkspace(_ id: UUID) {
        let store = TabWorkspaceStore.shared
        store.activate(id)

        let candidates = tabWindows.filter {
            ($0 as? TerminalWindow)?.isTabPinned != true && store.workspaceID(of: $0) == id
        }
        if let last = store.lastSelectedWindow(in: id), candidates.contains(where: { $0 === last }) {
            select(ObjectIdentifier(last))
        } else if let first = candidates.first {
            select(ObjectIdentifier(first))
        } else {
            newTab()
        }
    }

    func moveTab(_ id: Tab.ID, toWorkspace workspaceID: UUID) {
        guard let window = window(for: id) as? TerminalWindow else { return }
        let wasSelected = window === window.tabGroup?.selectedWindow
        window.isTabPinned = false
        window.workspaceID = workspaceID

        // Follow the selected tab so it doesn't vanish from under the user.
        if wasSelected { switchWorkspace(workspaceID) }
    }

    func promptNewWorkspace() {
        promptWorkspace(title: "New Workspace", name: "", icon: "") { [weak self] name, icon in
            let workspace = TabWorkspaceStore.shared.create(name: name, icon: icon)
            self?.switchWorkspace(workspace.id)
        }
    }

    func promptEditWorkspace(_ workspace: TabWorkspace) {
        promptWorkspace(title: "Edit Workspace", name: workspace.name, icon: workspace.icon) { name, icon in
            TabWorkspaceStore.shared.update(workspace.id, name: name, icon: icon)
        }
    }

    /// Delete a workspace after moving its tabs to the first other workspace.
    func deleteWorkspace(_ id: UUID) {
        let store = TabWorkspaceStore.shared
        guard let fallback = store.workspaces.first(where: { $0.id != id }) else { return }
        for window in tabWindows {
            guard let terminal = window as? TerminalWindow,
                  store.workspaceID(of: terminal) == id else { continue }
            terminal.workspaceID = fallback.id
        }
        TabSleepStore.shared.reassign(from: id, to: fallback.id)
        store.delete(id)
        switchWorkspace(store.activeID)
    }

    private func promptWorkspace(
        title: String,
        name: String,
        icon: String,
        completion: @escaping (String, String) -> Void
    ) {
        guard let window else { return }

        let editor = TabWorkspaceEditor(name: name, icon: icon)
        let accessory = NSHostingView(rootView: TabWorkspaceEditorView(editor: editor))
        accessory.frame = NSRect(x: 0, y: 0, width: 260, height: 28)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Pick an icon and a name. Without an icon the first letter of the name is used."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = editor.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            completion(name, editor.icon.isEmpty ? String(name.prefix(1)).uppercased() : editor.icon)
        }
    }

    // MARK: Layouts

    /// Save the tabs of the active workspace as a layout named after it.
    func saveWorkspaceAsLayout() {
        let store = TabWorkspaceStore.shared
        let workspace = store.active
        let layoutTabs = tabWindows
            .filter { ($0 as? TerminalWindow)?.isTabPinned != true && store.workspaceID(of: $0) == workspace.id }
            .compactMap(Self.layoutTab(of:))

        do {
            try TabLayoutStore.save(TabLayout(name: workspace.name, icon: workspace.icon, tabs: layoutTabs))
        } catch {
            Ghostty.logger.warning("failed to save tab layout: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Open a layout as a workspace. If a workspace with the layout's name already
    /// has tabs, switch to it instead of opening the tabs again.
    func openLayout(_ layout: TabLayout) {
        let store = TabWorkspaceStore.shared
        if let existing = store.workspaces.first(where: { $0.name == layout.name }),
           tabCount(in: existing.id) > 0 {
            switchWorkspace(existing.id)
            return
        }

        let workspace = store.workspaces.first { $0.name == layout.name }
            ?? store.create(name: layout.name, icon: layout.icon ?? String(layout.name.prefix(1)))
        store.activate(workspace.id)

        guard let parent = window,
              let ghostty = (parent.windowController as? BaseTerminalController)?.ghostty else { return }

        // Each tab opens after the previous one: opening them all from `parent`
        // would list them in reverse. The first tab is selected at the end.
        var anchor = parent
        var first: NSWindow?
        for tab in layout.tabs.isEmpty ? [TabLayout.Tab()] : layout.tabs {
            guard let opened = Self.openTab(tab, from: anchor, ghostty: ghostty)?.window else { continue }
            first = first ?? opened
            anchor = opened
        }
        if let first {
            first.tabGroup?.selectedWindow = first
            first.makeKeyAndOrderFront(nil)
        }
    }

    /// Open a tab described by a layout next to `parent`, with its splits,
    /// title and color.
    @discardableResult
    static func openTab(_ tab: TabLayout.Tab, from parent: NSWindow, ghostty: Ghostty.App) -> TerminalController? {
        let pane = tab.rootPane
        guard let controller = TerminalController.newTab(
            ghostty,
            from: parent,
            withBaseConfig: pane.leading.surfaceConfiguration) else { return nil }
        if let surface = controller.surfaceTree.first {
            buildSplits(pane, at: surface, in: controller)
        }
        if let title = tab.title, !title.isEmpty { controller.titleOverride = title }
        if let name = tab.color, let color = TerminalTabColor(name: name) {
            (controller.window as? TerminalWindow)?.tabColor = color
        }
        return controller
    }

    /// Describe an open tab as a layout tab: its splits, title and color.
    static func layoutTab(of window: NSWindow) -> TabLayout.Tab? {
        guard let controller = window.windowController as? TerminalController,
              let root = controller.surfaceTree.root else { return nil }
        let color = (window as? TerminalWindow)?.tabColor ?? .none
        let pane = layoutPane(root)
        return TabLayout.Tab(
            title: controller.titleOverride,
            cwd: pane.cwd,
            run: nil,
            color: color == .none ? nil : color.localizedName.lowercased(),
            split: pane.split)
    }

    /// Convert a split tree node to a layout pane.
    private static func layoutPane(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> TabLayout.Pane {
        switch node {
        case .leaf(let view):
            return .init(cwd: view.pwd.map { ($0 as NSString).abbreviatingWithTildeInPath })
        case .split(let split):
            return .init(split: .init(
                direction: split.direction == .horizontal ? "right" : "down",
                panes: [layoutPane(split.left), layoutPane(split.right)]))
        }
    }

    /// Create the splits of a layout pane. `surface` is the terminal for the
    /// pane, already created with the configuration of its leading pane.
    private static func buildSplits(
        _ pane: TabLayout.Pane,
        at surface: Ghostty.SurfaceView,
        in controller: TerminalController
    ) {
        guard let split = pane.split, split.panes.count == 2 else { return }
        let first = split.panes[0]
        let second = split.panes[1]

        guard let newSurface = controller.newSplit(
            at: surface,
            direction: split.direction == "down" ? .down : .right,
            baseConfig: second.leading.surfaceConfiguration) else { return }

        buildSplits(first, at: surface, in: controller)
        buildSplits(second, at: newSurface, in: controller)
    }

    /// Pinned tabs are shown as tiles at the top of the sidebar and are kept
    /// in front of all other tabs so they keep the lowest goto_tab numbers.
    func togglePin(_ id: Tab.ID) {
        guard let source = window(for: id) as? TerminalWindow else { return }
        source.isTabPinned.toggle()

        // Pinning moves the tab to the end of the pinned tabs, unpinning to
        // the start of the unpinned tabs. Both are the same boundary.
        let others = tabWindows.filter { $0 !== source }
        if let lastPinned = others.last(where: { ($0 as? TerminalWindow)?.isTabPinned == true }) {
            reorder(source, relativeTo: lastPinned, ordered: .above)
        } else if let first = others.first {
            reorder(source, relativeTo: first, ordered: .below)
        }
    }

    // MARK: Dragging

    /// What is being dragged in the sidebar: a tab, or a group by its label.
    enum DragItem: Equatable {
        case tab(Tab.ID)
        case group(UUID)
    }

    /// Where it is dropped. The sidebar draws a line there while dragging.
    enum DropTarget: Equatable {
        /// Above or below a tab in the list (its upper or lower half). The tab
        /// joins that tab's group, or leaves its own if that tab has none.
        case beforeTab(Tab.ID)
        case afterTab(Tab.ID)
        /// On a pinned tile: take its place.
        case tile(Tab.ID)
        /// Into a group, first: the lower part of its label.
        case group(UUID)
        /// Just above a group, outside it: the upper part of its label.
        case beforeGroup(UUID)
        /// First in the list (the workspace's name) or last (below the list).
        case start
        case end
    }

    func drop(_ item: DragItem, on target: DropTarget) {
        switch item {
        case .tab(let id) where isMultiSelected(id):
            dropTabs(selectedIDs, on: target)
            clearSelection()
        case .tab(let id): dropTab(id, on: target)
        case .group(let groupID): moveGroup(groupID, to: target)
        }
    }

    /// Dragging one of several picked tabs moves them all: the first lands
    /// where it's dropped and the others follow it, in the same group.
    private func dropTabs(_ ids: [Tab.ID], on target: DropTarget) {
        guard let first = ids.first else { return }
        dropTab(first, on: target)
        guard let lead = window(for: first) as? TerminalWindow else { return }

        var previous: NSWindow = lead
        for id in ids.dropFirst() {
            guard let window = window(for: id) as? TerminalWindow,
                  window.isTabPinned == lead.isTabPinned else { continue }
            let group = window.tabGroupID
            if !window.isTabPinned { window.tabGroupID = lead.tabGroupID }
            reorder(window, relativeTo: previous, ordered: .above)
            previous = window
            if let group, group != window.tabGroupID { deleteGroupIfEmpty(group) }
        }
    }

    /// The group a tab dropped on `target` ends up in; the sidebar colors the
    /// drop line with it.
    func groupAfterDrop(on target: DropTarget) -> UUID? {
        switch target {
        case .beforeTab(let id), .afterTab(let id):
            guard let window = window(for: id) as? TerminalWindow, !window.isTabPinned else { return nil }
            return TabGroupStore.shared.group(window.tabGroupID)?.id
        case .group(let groupID):
            return groupID
        case .tile, .beforeGroup, .start, .end:
            return nil
        }
    }

    /// Like Firefox: a tab dropped among a group's tabs or on its label joins
    /// the group; dropped among ungrouped tabs, above a group, at the top or
    /// below the list, it leaves it.
    private func dropTab(_ id: Tab.ID, on target: DropTarget) {
        guard let source = window(for: id) as? TerminalWindow else { return }
        let previous = source.tabGroupID

        switch target {
        case .beforeTab(let targetID), .afterTab(let targetID):
            guard let neighbor = window(for: targetID) as? TerminalWindow,
                  source.isTabPinned == neighbor.isTabPinned else { return }
            if !source.isTabPinned { source.tabGroupID = groupAfterDrop(on: target) }
            if source !== neighbor {
                reorder(source, relativeTo: neighbor, ordered: target == .afterTab(targetID) ? .above : .below)
            }

        case .tile(let targetID):
            move(id, to: targetID)

        case .group(let groupID):
            guard !source.isTabPinned else { return }
            source.tabGroupID = groupID
            if let first = members(of: groupID).first(where: { $0 !== source }) {
                reorder(source, relativeTo: first, ordered: .below)
            }

        case .beforeGroup(let groupID):
            guard !source.isTabPinned else { return }
            source.tabGroupID = nil
            if let first = members(of: groupID).first(where: { $0 !== source }) {
                reorder(source, relativeTo: first, ordered: .below)
            }

        case .start:
            guard !source.isTabPinned else { return }
            source.tabGroupID = nil
            if let first = firstWorkspaceWindow(excluding: [source]) {
                reorder(source, relativeTo: first, ordered: .below)
            }

        case .end:
            guard !source.isTabPinned else { return }
            source.tabGroupID = nil
            if let last = lastWorkspaceWindow(excluding: [source]) {
                reorder(source, relativeTo: last, ordered: .above)
            }
        }

        if let previous, previous != source.tabGroupID { deleteGroupIfEmpty(previous) }
    }

    /// Move all of a group's tabs, in order, before or after the tab or group
    /// they are dropped on. Groups never end up inside other groups: next to a
    /// grouped tab, they go before or after its whole group.
    private func moveGroup(_ groupID: UUID, to target: DropTarget) {
        let moving = members(of: groupID)
        guard !moving.isEmpty else { return }

        let block: [NSWindow]
        let after: Bool
        switch target {
        case .beforeTab(let targetID), .afterTab(let targetID):
            guard let window = window(for: targetID) as? TerminalWindow,
                  !window.isTabPinned, window.tabGroupID != groupID else { return }
            if let other = TabGroupStore.shared.group(window.tabGroupID)?.id {
                block = members(of: other)
            } else {
                block = [window]
            }
            after = target == .afterTab(targetID)
        case .group(let other), .beforeGroup(let other):
            guard other != groupID else { return }
            block = members(of: other)
            after = false
        case .start:
            guard let first = firstWorkspaceWindow(excluding: moving) else { return }
            block = [first]
            after = false
        case .end:
            guard let last = lastWorkspaceWindow(excluding: moving) else { return }
            block = [last]
            after = true
        case .tile:
            return
        }
        guard let blockFirst = block.first, let blockLast = block.last else { return }

        if after {
            var previous = blockLast
            for window in moving {
                reorder(window, relativeTo: previous, ordered: .above)
                previous = window
            }
        } else {
            for window in moving { reorder(window, relativeTo: blockFirst, ordered: .below) }
        }
    }

    /// The unpinned tabs of the active workspace, minus `excluded`.
    private func workspaceWindows(excluding excluded: [NSWindow]) -> [NSWindow] {
        let active = TabWorkspaceStore.shared.activeID
        return tabWindows.filter { window in
            !excluded.contains(window)
                && (window as? TerminalWindow)?.isTabPinned != true
                && TabWorkspaceStore.shared.workspaceID(of: window) == active
        }
    }

    private func firstWorkspaceWindow(excluding excluded: [NSWindow]) -> NSWindow? {
        workspaceWindows(excluding: excluded).first
    }

    private func lastWorkspaceWindow(excluding excluded: [NSWindow]) -> NSWindow? {
        workspaceWindows(excluding: excluded).last
    }

    /// Move the tab `id` to the position currently held by `targetID`. Tabs only
    /// move within their own section (pinned or not).
    func move(_ id: Tab.ID, to targetID: Tab.ID) {
        guard id != targetID,
              let source = window(for: id),
              let target = window(for: targetID),
              (source as? TerminalWindow)?.isTabPinned == (target as? TerminalWindow)?.isTabPinned,
              let windows = source.tabGroup?.windows,
              let sourceIndex = windows.firstIndex(of: source),
              let targetIndex = windows.firstIndex(of: target) else { return }

        reorder(source, relativeTo: target, ordered: sourceIndex < targetIndex ? .above : .below)
    }

    private func reorder(_ source: NSWindow, relativeTo target: NSWindow, ordered: NSWindow.OrderingMode) {
        guard source !== target, let tabGroup = source.tabGroup else { return }
        let selected = tabGroup.selectedWindow

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tabGroup.removeWindow(source)
        target.addTabbedWindowSafely(source, ordered: ordered)
        selected?.makeKey()
        NSAnimationContext.endGrouping()

        (selected?.windowController as? TerminalController)?.relabelTabs()
    }
}

// MARK: - Views

/// Places the tab sidebar next to (pinned) or over (collapsed) the terminal.
struct TabSidebarContainer<Content: View>: View {
    @ObservedObject private var state = TabSidebarState.shared
    @ObservedObject var model: TabSidebarModel
    let backgroundColor: Color
    let content: Content

    /// The width while the resize handle is being dragged. The terminal is only
    /// resized once the drag ends so it doesn't reflow on every mouse move.
    @State private var dragWidth: CGFloat?

    init(model: TabSidebarModel, backgroundColor: Color, @ViewBuilder content: () -> Content) {
        self.model = model
        self.backgroundColor = backgroundColor
        self.content = content()
    }

    private var sidebarWidth: CGFloat { dragWidth ?? state.width }

    var body: some View {
        content
            // Never animate the terminal size: every intermediate size would
            // resize the pty and make the shell redraw its prompt. The sidebar
            // slides over the terminal instead and the terminal jumps once.
            .padding(.leading, state.isEnabled && state.isPinned ? state.width + 1 : 0)
            .transaction { $0.animation = nil }
            .overlay(alignment: .leading) {
                if state.isEnabled && state.isPinned {
                    pinnedSidebar
                        .transition(.move(edge: .leading))
                }
            }
            .overlay {
                if state.isEnabled && !state.isPinned && state.isRevealed {
                    GeometryReader { geo in
                        floatingSidebar
                            .frame(height: geo.size.height * TabSidebarState.floatingHeightFraction)
                            .padding(.leading, 6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
    }

    private var pinnedSidebar: some View {
        HStack(spacing: 0) {
            TabSidebarView(model: model)
                .frame(width: sidebarWidth)
                .background(Color.black.opacity(0.12))
                .background(backgroundColor.opacity(0.88))

            Divider()
        }
        .overlay(alignment: .trailing) { resizeHandle }
    }

    private var floatingSidebar: some View {
        TabSidebarView(model: model)
            .frame(width: sidebarWidth)
            .modifier(FloatingSidebarBackground(tint: backgroundColor))
            .overlay(alignment: .trailing) { resizeHandle }
            .shadow(color: .black.opacity(0.35), radius: 14, x: 2, y: 0)
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: 4)
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        dragWidth = TabSidebarState.clampWidth(state.width + value.translation.width)
                    }
                    .onEnded { _ in
                        if let dragWidth { state.width = dragWidth }
                        dragWidth = nil
                    })
    }
}

struct TabSidebarView: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject private var store = TabWorkspaceStore.shared
    @ObservedObject private var sleepStore = TabSleepStore.shared
    @State private var dragging: TabSidebarModel.DragItem?
    @State private var dropTarget: TabSidebarModel.DropTarget?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TabSidebarSearchField(query: $query, focusRequest: model.searchFocusRequest, onCancel: model.focusTerminal) {
                if let first = model.search(query).first {
                    if !first.isPinned { TabWorkspaceStore.shared.activate(first.workspaceID) }
                    model.select(first.id)
                    query = ""
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            if !query.isEmpty {
                searchResults
            } else {
                tabList
            }

            Divider().opacity(0.5)

            footer
        }
    }

    private var tabList: some View {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    if !model.pinnedTabs.isEmpty {
                        LazyVGrid(columns: Self.pinnedColumns, spacing: 6) {
                            ForEach(model.pinnedTabs) { tab in
                                draggable(TabSidebarTile(tab: tab, model: model), id: tab.id)
                                    .onDrop(of: [.text], delegate: dropDelegate(.tile(tab.id)))
                            }
                        }

                        Divider().opacity(0.5)
                    }

                    if !model.hiddenAttentionTabs.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Image(systemName: "bell.badge")
                                Text("Needs Attention")
                                Spacer()
                                Text("⌘J")
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)

                            ForEach(model.hiddenAttentionTabs) { tab in
                                TabSidebarRow(tab: tab, model: model, showsWorkspace: true)
                            }
                        }

                        Divider().opacity(0.5)
                    }

                    HStack(spacing: 6) {
                        TabIcon(icon: store.active.icon)
                        Text(store.active.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .contextMenu { TabWorkspaceMenu(workspace: store.active, model: model) }
                    // Dropping on the workspace's name puts a tab first, outside any group.
                    .overlay(alignment: .bottom) { dropLine(.start, edge: .bottom) }
                    .onDrop(of: [.text], delegate: dropDelegate(.start))

                    LazyVStack(spacing: 2) {
                        ForEach(model.workspaceItems) { item in
                            switch item {
                            case .tab(let tab):
                                draggable(groupedRow(tab), id: tab.id)
                                    .overlay(alignment: .top) { dropLine(.beforeTab(tab.id), edge: .top) }
                                    .overlay(alignment: .bottom) { dropLine(.afterTab(tab.id), edge: .bottom) }
                                    .modifier(TabSidebarDropZone(
                                        upper: .beforeTab(tab.id), lower: .afterTab(tab.id), split: 0.5,
                                        delegate: dropDelegate))
                                    .transition(.opacity.combined(with: .offset(y: -6)))
                            case .group(let group, let count):
                                TabGroupLabel(group: group, count: count, model: model)
                                    .onDrag {
                                        dragging = .group(group.id)
                                        return NSItemProvider(object: group.id.uuidString as NSString)
                                    }
                                    .overlay(alignment: .top) { dropLine(.beforeGroup(group.id), edge: .top) }
                                    .overlay(alignment: .bottom) { dropLine(.group(group.id), edge: .bottom) }
                                    // The upper third of the label means "above the group".
                                    .modifier(TabSidebarDropZone(
                                        upper: .beforeGroup(group.id), lower: .group(group.id), split: 1 / 3,
                                        delegate: dropDelegate))
                            }
                        }

                        ForEach(model.sleepingTabs) { sleeping in
                            TabSidebarSleepingRow(sleeping: sleeping, model: model)
                        }

                        // Dropping below the list moves a tab out of its group
                        // to the end, or a group to the end.
                        Color.clear
                            .frame(height: 36)
                            .contentShape(Rectangle())
                            .overlay(alignment: .top) { dropLine(.end, edge: .top) }
                            .onDrop(of: [.text], delegate: dropDelegate(.end))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            // Right-clicking the empty part of the sidebar shows its options.
            .contentShape(Rectangle())
            .contextMenu { TabSidebarBackgroundMenu(model: model) }
    }

    private var searchResults: some View {
        ScrollView(.vertical, showsIndicators: false) {
            let results = model.search(query)
            LazyVStack(spacing: 2) {
                if results.isEmpty {
                    Text("No matching tabs")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 12)
                }

                ForEach(results) { tab in
                    TabSidebarRow(tab: tab, model: model, showsWorkspace: true)
                        .simultaneousGesture(TapGesture().onEnded { query = "" })
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            WispUpdateBanner()
                .padding(.horizontal, 8)
                .padding(.top, 6)

            Button(action: model.newTab) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("New Tab")
                    Spacer()
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 6)

            TabWorkspaceBar(model: model)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
    }

    /// A tab row, with its group's color along the left when it's in one.
    @ViewBuilder
    private func groupedRow(_ tab: TabSidebarModel.Tab) -> some View {
        if let color = TabGroupStore.shared.group(tab.groupID)?.color.displayColor {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(nsColor: color))
                    .frame(width: 3)
                    .padding(.vertical, 4)
                TabSidebarRow(tab: tab, model: model)
            }
            .padding(.leading, 6)
        } else {
            TabSidebarRow(tab: tab, model: model)
        }
    }

    private static let pinnedColumns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 3)

    private func draggable<V: View>(_ view: V, id: TabSidebarModel.Tab.ID) -> some View {
        view.onDrag {
            dragging = .tab(id)
            return NSItemProvider(object: "\(id.hashValue)" as NSString)
        }
    }

    /// Where a dragged tab would land: in the group's color when it would join
    /// a group, light gray otherwise. Groups never join one, so theirs is gray.
    private func dropLine(_ target: TabSidebarModel.DropTarget, edge: VerticalEdge) -> some View {
        var color = Color.secondary.opacity(0.55)
        if case .tab = dragging,
           let groupColor = TabGroupStore.shared.group(model.groupAfterDrop(on: target))?.color.displayColor {
            color = Color(nsColor: groupColor)
        }
        return Capsule()
            .fill(color)
            .frame(height: 2)
            .padding(.horizontal, 4)
            .offset(y: edge == .top ? -2 : 2)
            .opacity(dragging != nil && dropTarget == target ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func dropDelegate(
        _ target: TabSidebarModel.DropTarget,
        _ resolve: ((CGPoint) -> TabSidebarModel.DropTarget)? = nil
    ) -> TabSidebarDropDelegate {
        TabSidebarDropDelegate(
            target: target, resolve: resolve, model: model,
            dragging: $dragging, dropTarget: $dropTarget)
    }
}

/// Search field at the top of the sidebar. Return selects the first match and
/// Escape clears the search.
private struct TabSidebarSearchField: View {
    @Binding var query: String
    let focusRequest: Int
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search tabs", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(onSubmit)
                .onExitCommand {
                    query = ""
                    onCancel()
                }
                .onChange(of: focusRequest) { _ in
                    TabSidebarState.shared.keepsRevealed = true
                    DispatchQueue.main.async { isFocused = true }
                }
                .onChange(of: isFocused) { focused in
                    if !focused { TabSidebarState.shared.keepsRevealed = false }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07)))
    }
}

/// Workspace switcher at the bottom of the sidebar, like Zen's.
private struct TabWorkspaceBar: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject private var store = TabWorkspaceStore.shared

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        let isActive = workspace.id == store.activeID
                        Button {
                            model.switchWorkspace(workspace.id)
                        } label: {
                            TabIcon(icon: workspace.icon)
                                .font(.system(size: 14))
                                .frame(width: 28, height: 26)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.primary.opacity(isActive ? 0.16 : 0)))
                                .opacity(isActive || model.tabCount(in: workspace.id) > 0 ? 1 : 0.5)
                                .overlay(alignment: .topTrailing) {
                                    if model.needsAttention(in: workspace.id) {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 6, height: 6)
                                            .offset(x: -2, y: 2)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(index < 9 ? "\(workspace.name) (⇧⌘\(index + 1))" : workspace.name)
                        .contextMenu { TabWorkspaceMenu(workspace: workspace, model: model) }
                    }
                }
            }

            Menu {
                Button("New Workspace…", action: model.promptNewWorkspace)

                Divider()

                let layouts = TabLayoutStore.load()
                if layouts.isEmpty {
                    Text("No Saved Layouts")
                } else {
                    ForEach(layouts) { layout in
                        Button { model.openLayout(layout) } label: {
                            TabIconLabel(icon: layout.icon ?? "", title: "Open \(layout.name)")
                        }
                    }
                }

                Divider()

                Button("Save Workspace as Layout", action: model.saveWorkspaceAsLayout)
                Button("Edit Layouts File…") { TabLayoutStore.openFile() }

                Divider()

                Button("Agent Monitor") { AgentMonitorWindowController.shared.toggle() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Workspaces and Layouts")
        }
        .frame(height: 30)
    }
}

/// The values edited by the workspace alert.
final class TabWorkspaceEditor: ObservableObject {
    @Published var name: String
    @Published var icon: String

    init(name: String, icon: String) {
        self.name = name
        self.icon = icon
    }
}

/// Icon picker and name field shown in the workspace alert.
private struct TabWorkspaceEditorView: View {
    @ObservedObject var editor: TabWorkspaceEditor
    @State private var isPickingIcon = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isPickingIcon.toggle()
            } label: {
                Group {
                    if editor.icon.isEmpty {
                        Image(systemName: "face.smiling")
                            .foregroundStyle(.secondary)
                    } else {
                        TabIcon(icon: editor.icon)
                    }
                }
                .font(.system(size: 16))
                .frame(width: 36, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose Icon")
            .popover(isPresented: $isPickingIcon, arrowEdge: .bottom) {
                TabIconPicker(selection: $editor.icon) { isPickingIcon = false }
            }

            TextField("Name", text: $editor.name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
        }
        .onAppear { nameFocused = true }
    }
}

/// Context menu for a workspace.
private struct TabWorkspaceMenu: View {
    let workspace: TabWorkspace
    let model: TabSidebarModel

    var body: some View {
        Button("Edit Workspace…") { model.promptEditWorkspace(workspace) }
        Button("Delete Workspace") { model.deleteWorkspace(workspace.id) }
            .disabled(TabWorkspaceStore.shared.workspaces.count <= 1)
    }
}

/// A pinned tab, shown as a tile in a grid at the top of the sidebar.
private struct TabSidebarTile: View {
    let tab: TabSidebarModel.Tab
    @ObservedObject var model: TabSidebarModel
    @ObservedObject private var state = TabSidebarState.shared
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "terminal")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)

                if state.colorStyle == .dot, let color = tab.color.displayColor {
                    TabColorDot(color: color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if tab.needsAttention {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                } else {
                    TabActivityIndicator(activity: tab.activity)
                }
            }

            Text(tab.title)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .foregroundStyle(tab.isSelected ? .primary : .secondary)
        .padding(.horizontal, 6)
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(background))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(tab.isSelected ? Color.primary.opacity(0.3) : Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .modifier(TabPreviewOnHover(tab: tab, model: model, isHovering: isHovering))
        .modifier(TabMultiSelectionOutline(isSelected: model.isMultiSelected(tab.id), cornerRadius: 9))
        .onTapGesture { model.click(tab.id) }
        .contextMenu { TabSidebarContextMenu(tab: tab, model: model) }
    }

    private var background: Color {
        if state.colorStyle == .fill, let color = tab.color.displayColor {
            return Color(nsColor: color).opacity(tab.isSelected ? 0.55 : 0.3)
        }

        if model.isMultiSelected(tab.id) { return Color.accentColor.opacity(0.22) }
        if tab.isSelected { return Color.primary.opacity(0.16) }
        return Color.primary.opacity(isHovering ? 0.1 : 0.06)
    }
}

/// Shows that a program in the tab reports progress: a spinner while busy, a
/// ring for a known percentage, and a warning on error.
private struct TabActivityIndicator: View {
    let activity: TabSidebarModel.Activity

    var body: some View {
        switch activity {
        case .idle:
            EmptyView()

        case .busy:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)
                .help("Running")

        case .progress(let value):
            ZStack {
                Circle().stroke(Color.primary.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: value)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 10, height: 10)
            .help("\(Int(value * 100))%")

        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .help("Error")
        }
    }
}

/// How long the current command has run, or when the last one finished. Short
/// commands are not shown so the sidebar isn't busy with every `ls`.
private struct TabCommandBadge: View {
    let state: TabCommandState

    private static let minimumRunning: TimeInterval = 2
    private static let minimumFinished: TimeInterval = 5

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var body: some View {
        // Running commands tick every second; "finished 3m ago" only needs minutes.
        TimelineView(.periodic(from: .now, by: isRunning ? 1 : 30)) { context in
            switch state {
            case .running(let since):
                let elapsed = context.date.timeIntervalSince(since)
                if elapsed >= Self.minimumRunning {
                    HStack(spacing: 2) {
                        Image(systemName: "timer")
                        Text(elapsed.compactDuration)
                            .monospacedDigit()
                    }
                    .help("Running for \(elapsed.compactDuration)")
                }

            case .finished(let at, let exitCode, let duration):
                if duration >= Self.minimumFinished {
                    let ago = context.date.timeIntervalSince(at)
                    let failed = (exitCode ?? 0) != 0
                    HStack(spacing: 2) {
                        Image(systemName: failed ? "xmark" : "checkmark")
                            .foregroundStyle(failed ? Color.red : Color.green)
                        Text(ago < 60 ? "now" : ago.compactDuration)
                            .monospacedDigit()
                    }
                    .help(failed
                        ? "Failed with exit code \(exitCode ?? 0) after \(duration.compactDuration)"
                        : "Finished \(ago.compactDuration) ago after \(duration.compactDuration)")
                }
            }
        }
    }
}

/// An unloaded tab: dimmed, with a moon. Clicking opens it again.
private struct TabSidebarSleepingRow: View {
    let sleeping: SleepingTab
    let model: TabSidebarModel
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(sleeping.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if let directory = sleeping.directory {
                    Text(directory)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
        }
        .foregroundStyle(.secondary)
        .opacity(isHovering ? 0.9 : 0.6)
        .padding(.horizontal, 10)
        .frame(height: sleeping.directory == nil ? 30 : 40)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .help("Unloaded \(sleeping.sleptAt.formatted(.relative(presentation: .named))). Click to open it again.")
        .onHover { isHovering = $0 }
        .onTapGesture { model.wake(sleeping.id) }
        .contextMenu {
            Button("Open Tab") { model.wake(sleeping.id) }
            Button("Close Tab") { TabSleepStore.shared.remove(sleeping.id) }
        }
    }
}

/// The menu for the sidebar's empty space: new tabs and sidebar options.
private struct TabSidebarBackgroundMenu: View {
    let model: TabSidebarModel
    @ObservedObject private var state = TabSidebarState.shared
    @ObservedObject private var sleep = TabSleepStore.shared

    var body: some View {
        Button("New Tab", action: model.newTab)
        Button("New Workspace…", action: model.promptNewWorkspace)

        Divider()

        Toggle("Show Folder, Branch and Command Time", isOn: $state.showsDetails)
        Toggle("Preview Tabs on Hover", isOn: $state.showsPreview)
        Picker("Group Labels", selection: $state.groupLabelStyle) {
            ForEach(TabGroupLabelStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker("Tab Colors", selection: $state.colorStyle) {
            ForEach(TabColorStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker("Unload Idle Tabs", selection: $sleep.autoUnloadMinutes) {
            ForEach(TabSleepStore.autoUnloadChoices, id: \.self) { minutes in
                Text(minutes == 0 ? "Manually" : minutes < 60 ? "After \(minutes) Minutes" : "After \(minutes / 60) Hour\(minutes == 60 ? "" : "s")")
                    .tag(minutes)
            }
        }

        Divider()

        TabSidebarLayoutMenu()

        Divider()

        Button("Agent Monitor") { AgentMonitorWindowController.shared.toggle() }
        Button("Settings…") { WispSettingsWindowController.shared.show() }
    }
}

/// Tab layout options shared by the sidebar menus.
struct TabSidebarLayoutMenu: View {
    @ObservedObject private var state = TabSidebarState.shared

    var body: some View {
        Button(state.isPinned ? "Collapse Sidebar" : "Pin Sidebar") {
            _ = state.togglePinned()
        }
        .keyboardShortcut("e", modifiers: .command)
        Button("Use Horizontal Tabs") { state.setEnabled(false) }
    }
}

/// Shows the visible text of a tab in a popover after hovering it for a moment.
private struct TabPreviewOnHover: ViewModifier {
    let tab: TabSidebarModel.Tab
    let model: TabSidebarModel
    let isHovering: Bool

    @State private var preview: String?
    @State private var isPresented = false

    private static let delay: Duration = .milliseconds(600)

    func body(content: Content) -> some View {
        content
            .task(id: isHovering) {
                guard isHovering, !tab.isSelected, TabSidebarState.shared.showsPreview else {
                    isPresented = false
                    return
                }
                try? await Task.sleep(for: Self.delay)
                guard !Task.isCancelled, isHovering else { return }
                preview = model.previewText(for: tab.id)
                isPresented = preview != nil
            }
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tab.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(preview ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(width: 460, alignment: .leading)
            }
    }
}

/// The context menu shared by sidebar rows and pinned tiles.
private struct TabSidebarContextMenu: View {
    let tab: TabSidebarModel.Tab
    let model: TabSidebarModel

    var body: some View {
        if model.isMultiSelected(tab.id) {
            TabSelectionMenu(model: model)
        } else {
            singleTabMenu
        }
    }

    @ViewBuilder
    private var singleTabMenu: some View {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab.id) }
        Button("Rename Tab…") { model.rename(tab.id) }
        Menu("Move to Workspace") {
            ForEach(TabWorkspaceStore.shared.workspaces) { workspace in
                Button { model.moveTab(tab.id, toWorkspace: workspace.id) } label: {
                    TabIconLabel(icon: workspace.icon, title: workspace.name)
                }
                .disabled(!tab.isPinned && workspace.id == tab.workspaceID)
            }
        }
        TabColorMenu(tab: tab, model: model)
        Divider()
        if !tab.isPinned {
            TabGroupMenu(tab: tab, model: model)
            Divider()
            Button("Unload Tab") { model.unload(tab.id) }
        }
        Button("Close Tab") { model.close(tab.id) }
        Button("Close Other Tabs") { model.closeOthers(tab.id) }
        Divider()
        TabSidebarLayoutMenu()
    }
}

/// Liquid glass on macOS 26 and later, a tinted material before that.
private struct FloatingSidebarBackground: ViewModifier {
    let tint: Color

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .background(tint.opacity(0.45), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(tint.opacity(0.92))
            .background(.ultraThinMaterial)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
    }
}

private struct TabSidebarRow: View {
    let tab: TabSidebarModel.Tab
    @ObservedObject var model: TabSidebarModel
    var showsWorkspace = false
    @ObservedObject private var state = TabSidebarState.shared
    @State private var isHovering = false
    @State private var draft = ""
    @FocusState private var titleFocused: Bool

    private var isRenaming: Bool { model.renamingID == tab.id }

    var body: some View {
        HStack(spacing: 6) {
            if tab.needsAttention {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .help("Needs attention")
            }

            TabActivityIndicator(activity: tab.activity)

            if state.colorStyle == .dot, let color = tab.color.displayColor {
                TabColorDot(color: color)
                    .help(tab.color.localizedName)
            }

            if showsWorkspace,
               let workspace = TabWorkspaceStore.shared.workspaces.first(where: { $0.id == tab.workspaceID }) {
                TabIcon(icon: workspace.icon)
                    .font(.system(size: 11))
                    .help(workspace.name)
            }

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    // Return saves, Escape cancels, clicking elsewhere saves.
                    TextField("Tab title", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .focused($titleFocused)
                        .onSubmit { model.finishRenaming(tab.id, title: draft) }
                        .onExitCommand { model.finishRenaming(tab.id, title: nil) }
                        .onChange(of: titleFocused) { focused in
                            if !focused, isRenaming { model.finishRenaming(tab.id, title: draft) }
                        }
                } else {
                    Text(tab.title)
                        .font(.system(size: 12, weight: tab.isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(tab.isSelected ? .primary : .secondary)
                }

                if state.showsDetails, subtitle != nil || tab.command != nil {
                    HStack(spacing: 4) {
                        if let subtitle {
                            Text(subtitle)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                        if let command = tab.command {
                            TabCommandBadge(state: command)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            if isHovering {
                Button {
                    model.close(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab")
            } else if !tab.keyEquivalent.isEmpty {
                Text(tab.keyEquivalent)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: state.showsDetails && (subtitle != nil || tab.command != nil) ? 40 : 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tab.isSelected ? Color.primary.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .modifier(TabPreviewOnHover(tab: tab, model: model, isHovering: isHovering))
        .modifier(TabMultiSelectionOutline(isSelected: model.isMultiSelected(tab.id), cornerRadius: 7))
        // Selecting happens on the first click so it isn't delayed while
        // waiting to see whether a second click follows.
        .onTapGesture(count: 2) { model.rename(tab.id) }
        .simultaneousGesture(TapGesture().onEnded { if !isRenaming { model.click(tab.id) } })
        .onChange(of: model.renamingID) { id in
            guard id == tab.id else { return }
            draft = model.editableTitle(tab.id)
            DispatchQueue.main.async { titleFocused = true }
        }
        .contextMenu { TabSidebarContextMenu(tab: tab, model: model) }
    }

    /// The folder and git branch, e.g. `ghostty · main`.
    private var subtitle: String? {
        guard let directory = tab.directory else { return nil }
        let folder = directory == "~" ? "~" : (directory as NSString).lastPathComponent
        if let branch = tab.branch { return "\(folder) · \(branch)" }
        return directory
    }

    /// Colored tabs are filled with their color, stronger when selected, unless
    /// the color is shown as a dot.
    private var background: Color {
        if state.colorStyle == .fill, let color = tab.color.displayColor {
            return Color(nsColor: color).opacity(tab.isSelected ? 0.55 : 0.28)
        }

        if model.isMultiSelected(tab.id) { return Color.accentColor.opacity(0.22) }
        if tab.isSelected { return Color.primary.opacity(0.14) }
        if isHovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}

/// A drop area that means one thing in its upper part and another below
/// (above/below a tab, above/into a group).
private struct TabSidebarDropZone: ViewModifier {
    let upper: TabSidebarModel.DropTarget
    let lower: TabSidebarModel.DropTarget
    /// The fraction of the height that counts as upper.
    let split: CGFloat
    let delegate: (TabSidebarModel.DropTarget, ((CGPoint) -> TabSidebarModel.DropTarget)?) -> TabSidebarDropDelegate
    @State private var height: CGFloat = 30

    func body(content: Content) -> some View {
        let boundary = height * split
        let upper = upper
        let lower = lower
        return content
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { height = geometry.size.height }
                    .onChange(of: geometry.size.height) { height = $0 }
            })
            .onDrop(of: [.text], delegate: delegate(lower) { $0.y < boundary ? upper : lower })
    }
}

private struct TabSidebarDropDelegate: DropDelegate {
    let target: TabSidebarModel.DropTarget
    /// For views that mean different things depending on where the pointer is.
    let resolve: ((CGPoint) -> TabSidebarModel.DropTarget)?
    let model: TabSidebarModel
    @Binding var dragging: TabSidebarModel.DragItem?
    @Binding var dropTarget: TabSidebarModel.DropTarget?

    private func target(at info: DropInfo) -> TabSidebarModel.DropTarget {
        resolve?(info.location) ?? target
    }

    // Updates can still arrive after the drop; once `dragging` is cleared
    // they are ignored so the line doesn't come back.
    func dropEntered(info: DropInfo) {
        if dragging != nil { dropTarget = target(at: info) }
    }

    func dropExited(info: DropInfo) {
        if let current = dropTarget, current == target(at: info) || current == target || current == resolve?(.zero) {
            dropTarget = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if dragging != nil { dropTarget = target(at: info) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = target(at: info)
        let item = dragging
        dragging = nil
        dropTarget = nil
        guard let item else { return false }
        model.drop(item, on: target)
        return true
    }
}
