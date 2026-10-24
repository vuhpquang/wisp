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

    static let width: CGFloat = 220

    /// How close to the left edge of the window the mouse has to be to reveal
    /// a collapsed sidebar.
    private static let revealEdge: CGFloat = 6

    private static let pinnedKey = "TabSidebarPinned"

    /// Whether the sidebar takes up space next to the terminal. When false the
    /// sidebar is collapsed and floats over the terminal on hover.
    @Published var isPinned: Bool {
        didSet { UserDefaults.ghostty.set(isPinned, forKey: Self.pinnedKey) }
    }

    /// Whether a collapsed sidebar is temporarily shown because the mouse is
    /// at the left edge of the window.
    @Published private(set) var isRevealed = false

    private var mouseMonitor: Any?

    private init() {
        isPinned = UserDefaults.ghostty.object(forKey: Self.pinnedKey) as? Bool ?? true
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

    private func handleMouse(_ event: NSEvent) {
        guard !isPinned else { return }
        guard let window = event.window as? TerminalWindow, window.usesVerticalTabs else { return }

        let x = event.locationInWindow.x
        if !isRevealed, x <= Self.revealEdge {
            withAnimation(.easeOut(duration: 0.15)) { isRevealed = true }
        } else if isRevealed, x > Self.width + 32 {
            withAnimation(.easeIn(duration: 0.15)) { isRevealed = false }
        }
    }
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
    }

    @Published private(set) var tabs: [Tab] = []

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var reloadScheduled = false

    init(window: NSWindow) {
        self.window = window

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            TabSidebarState.tabsDidChange,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            .terminalWindowBellDidChangeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleReload()
            })
        }

        TabSidebarState.shared.installMouseMonitorIfNeeded()
        reload()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Coalesce bursts of notifications into one reload on the next loop
    /// iteration, after AppKit has settled the tab group.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reload()
        }
    }

    private func reload() {
        let windows = tabWindows
        let selected = window?.tabGroup?.selectedWindow ?? window
        let newTabs = windows.map { w in
            let terminal = w as? TerminalWindow
            return Tab(
                id: ObjectIdentifier(w),
                title: w.title.isEmpty ? "👻" : w.title,
                color: terminal?.tabColor ?? .none,
                isSelected: w === selected,
                keyEquivalent: terminal?.keyEquivalent ?? "",
                hasBell: (w.windowController as? BaseTerminalController)?.bell ?? false)
        }

        if newTabs != tabs { tabs = newTabs }
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

    func rename(_ id: Tab.ID) {
        (window(for: id)?.windowController as? BaseTerminalController)?.promptTabTitle()
    }

    func setColor(_ color: TerminalTabColor, for id: Tab.ID) {
        (window(for: id) as? TerminalWindow)?.tabColor = color
    }

    /// Move the tab `id` to the position currently held by `targetID`.
    func move(_ id: Tab.ID, to targetID: Tab.ID) {
        guard id != targetID,
              let source = window(for: id),
              let target = window(for: targetID),
              let tabGroup = source.tabGroup else { return }

        let windows = tabGroup.windows
        guard let sourceIndex = windows.firstIndex(of: source),
              let targetIndex = windows.firstIndex(of: target) else { return }

        let selected = tabGroup.selectedWindow

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tabGroup.removeWindow(source)
        target.addTabbedWindowSafely(source, ordered: sourceIndex < targetIndex ? .above : .below)
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

    init(model: TabSidebarModel, backgroundColor: Color, @ViewBuilder content: () -> Content) {
        self.model = model
        self.backgroundColor = backgroundColor
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            if state.isPinned {
                TabSidebarView(model: model)
                    .frame(width: TabSidebarState.width)
                    .background(Color.black.opacity(0.12))
                    .transition(.move(edge: .leading))

                Divider()
            }

            content
        }
        .overlay(alignment: .topLeading) {
            if !state.isPinned && state.isRevealed {
                TabSidebarView(model: model)
                    .frame(width: TabSidebarState.width)
                    .frame(maxHeight: .infinity)
                    .background(backgroundColor.opacity(0.92))
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.35), radius: 14, x: 2, y: 0)
                    .padding(6)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }
}

struct TabSidebarView: View {
    @ObservedObject var model: TabSidebarModel
    @State private var draggingID: TabSidebarModel.Tab.ID?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(model.tabs) { tab in
                        TabSidebarRow(tab: tab, model: model)
                            .onDrag {
                                draggingID = tab.id
                                return NSItemProvider(object: "\(tab.id.hashValue)" as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabSidebarDropDelegate(
                                target: tab.id,
                                model: model,
                                draggingID: $draggingID))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            Divider().opacity(0.5)

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
            .padding(.vertical, 6)
        }
    }
}

private struct TabSidebarRow: View {
    let tab: TabSidebarModel.Tab
    @ObservedObject var model: TabSidebarModel
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.hasBell && !tab.isSelected {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .help("This tab rang the bell")
            }

            Text(tab.title)
                .font(.system(size: 12, weight: tab.isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(tab.isSelected ? .primary : .secondary)

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
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tab.isSelected ? Color.primary.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { model.select(tab.id) }
        .contextMenu {
            Button("Rename Tab…") { model.rename(tab.id) }
            Menu("Tab Color") {
                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                    Button(color.localizedName) { model.setColor(color, for: tab.id) }
                }
            }
            Divider()
            Button("Close Tab") { model.close(tab.id) }
            Button("Close Other Tabs") { model.closeOthers(tab.id) }
        }
    }

    /// Colored tabs are filled with their color, stronger when selected.
    private var background: Color {
        if let color = tab.color.displayColor {
            return Color(nsColor: color).opacity(tab.isSelected ? 0.55 : 0.28)
        }

        if tab.isSelected { return Color.primary.opacity(0.14) }
        if isHovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}

private struct TabSidebarDropDelegate: DropDelegate {
    let target: TabSidebarModel.Tab.ID
    let model: TabSidebarModel
    @Binding var draggingID: TabSidebarModel.Tab.ID?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingID else { return false }
        model.move(draggingID, to: target)
        self.draggingID = nil
        return true
    }
}
