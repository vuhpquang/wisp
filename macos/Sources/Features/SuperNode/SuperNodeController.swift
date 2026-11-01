import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// SuperNode mode: terminals, agents, notes and diffs as nodes on an infinite
/// canvas, connected to show how they relate. It lives in its own window;
/// turning it off brings back the normal Wisp terminal window.
final class SuperNodeController: NSWindowController, NSWindowDelegate, ObservableObject {
    static let shared = SuperNodeController()

    /// Whether the SuperNode window is showing.
    @Published private(set) var isActive = false

    private var canvas: SuperNodeCanvasView?

    /// The terminal window SuperNode was turned on from, shown again when it's
    /// turned off.
    private weak var returnWindow: NSWindow?

    private var ghostty: Ghostty.App? {
        (NSApp.delegate as? AppDelegate)?.ghostty
    }

    private init() {
        let window = SuperNodeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        window.title = "SuperNode"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 320)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        super.init(window: window)
        window.delegate = self

        let toggle = NSTitlebarAccessoryViewController()
        toggle.layoutAttribute = .right
        toggle.view = NonDraggableHostingView(rootView: SuperNodeToggle(isCanvas: true, window: window))
        window.addTitlebarAccessoryViewController(toggle)
        toggle.view.translatesAutoresizingMaskIntoConstraints = false

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(surfaceDidClose(_:)), name: Ghostty.Notification.ghosttyCloseSurface, object: nil)
        center.addObserver(self, selector: #selector(surfaceDidRequestSplit(_:)), name: Ghostty.Notification.ghosttyNewSplit, object: nil)
        center.addObserver(self, selector: #selector(surfaceDidRequestTab(_:)), name: Ghostty.Notification.ghosttyNewTab, object: nil)
        center.addObserver(self, selector: #selector(surfaceDidRequestCloseTab(_:)), name: .ghosttyCloseTab, object: nil)
        center.addObserver(self, selector: #selector(surfaceDidRequestCloseTab(_:)), name: .ghosttyCloseWindow, object: nil)
        center.addObserver(self, selector: #selector(appWillTerminate(_:)), name: NSApplication.willTerminateNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Turning SuperNode on and off

    @objc func toggle(_ sender: Any?) {
        setActive(!isActive)
    }

    /// Shows or hides the SuperNode window. `source` is the terminal window the
    /// toggle was used in; SuperNode opens over it at the same size.
    func setActive(_ active: Bool, from source: NSWindow? = nil) {
        if active {
            show(from: source)
        } else {
            hide()
        }
    }

    private func show(from source: NSWindow?) {
        guard let window, let ghostty else { return }

        let source = source ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let source, source !== window, source.windowController is BaseTerminalController {
            returnWindow = source
            if !source.styleMask.contains(.fullScreen) {
                window.setFrame(source.frame, display: false)
            }
        }

        if canvas == nil {
            let canvas = SuperNodeCanvasView(ghostty: ghostty, document: SuperNodeStore.load())
            window.contentView = canvas
            window.backgroundColor = NSColor(ghostty.config.backgroundColor)
            self.canvas = canvas
            SuperNodeHookCenter.shared.onEvent = { [weak canvas] event in canvas?.handle(event) }
            SuperNodeHookCenter.shared.start()
        }

        isActive = true
        window.makeKeyAndOrderFront(nil)
        canvas?.setRefreshing(true)
        if let canvas, canvas.window?.firstResponder === window {
            window.makeFirstResponder(canvas)
        }
    }

    private func hide() {
        canvas?.save()
        canvas?.setRefreshing(false)
        isActive = false
        window?.orderOut(nil)

        // Bring back the terminal window SuperNode was opened from, or any
        // terminal window, or a new one if there are none left.
        if let returnWindow, returnWindow.windowController is BaseTerminalController {
            returnWindow.makeKeyAndOrderFront(nil)
        } else if let window = TerminalController.all.compactMap(\.window).first {
            window.makeKeyAndOrderFront(nil)
        } else if let ghostty {
            _ = TerminalController.newWindow(ghostty)
        }
    }

    // MARK: NSWindowDelegate

    // Closing the window turns SuperNode off; its terminals keep running.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    // Clicking a notification shows the window without the switch.
    func windowDidBecomeKey(_ notification: Notification) {
        guard !isActive, canvas != nil else { return }
        isActive = true
        canvas?.setRefreshing(true)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        canvas?.setRefreshing(isActive && window.occlusionState.contains(.visible))
    }

    // MARK: Terminal events

    // Terminals in nodes send the same requests as terminals in tabs. Splits
    // become connected nodes, new tabs become nodes, and closing closes the node.

    @objc private func surfaceDidClose(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView, canvas?.contains(surface) == true else { return }
        let processAlive = (notification.userInfo?["process_alive"] as? Bool) ?? false
        canvas?.close(surface: surface, confirm: processAlive)
    }

    @objc private func surfaceDidRequestSplit(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView, canvas?.contains(surface) == true else { return }
        guard let direction = notification.userInfo?["direction"] as? ghostty_action_split_direction_e else { return }
        let config = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration
        let newDirection: SplitTree<Ghostty.SurfaceView>.NewDirection
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT: newDirection = .left
        case GHOSTTY_SPLIT_DIRECTION_UP: newDirection = .up
        case GHOSTTY_SPLIT_DIRECTION_DOWN: newDirection = .down
        default: newDirection = .right
        }
        canvas?.split(surface, direction: newDirection, config: config)
    }

    @objc private func surfaceDidRequestTab(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView, canvas?.contains(surface) == true else { return }
        let config = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration
        canvas?.newTerminal(near: surface, config: config)
    }

    @objc private func surfaceDidRequestCloseTab(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView, canvas?.contains(surface) == true else { return }
        canvas?.close(surface: surface, confirm: true)
    }

    @objc private func appWillTerminate(_ notification: Notification) {
        canvas?.save()
        canvas?.saveScrollback(waiting: true)
    }

    /// A terminal on the canvas, for notifications to find when clicked.
    func surface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        canvas?.terminalNodes.first { $0.surface.id == uuid }?.surface
    }
}

// MARK: - Menu

extension SuperNodeController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggle(_:)) {
            menuItem.state = isActive ? .on : .off
        }
        return true
    }

    /// Window > SuperNode Mode (⌃⌘N), below Agent Monitor.
    static func installMenuItem() {
        guard let menu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu else { return }
        let item = NSMenuItem(title: "SuperNode Mode", action: #selector(toggle(_:)), keyEquivalent: "n")
        item.keyEquivalentModifierMask = [.command, .control]
        item.target = shared
        item.setImageIfDesired(systemSymbolName: "point.3.connected.trianglepath.dotted")
        let index = menu.items.firstIndex { $0.title == "Agent Monitor" }.map { $0 + 1 } ?? 0
        menu.insertItem(item, at: index)
    }
}

// MARK: - Window

/// The SuperNode window. Clicking anywhere in a node brings it to the front,
/// including clicks the terminal itself handles.
final class SuperNodeWindow: NSWindow {
    // ⌘⇧B switches between the canvas and the board, even from a terminal.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "b",
           let canvas = contentView as? SuperNodeCanvasView {
            canvas.toggleBoard()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        if result, let surface = responder as? Ghostty.SurfaceView,
           let canvas = contentView as? SuperNodeCanvasView {
            canvas.surfaceDidFocus(surface)
        }
        return result
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           let canvas = contentView as? SuperNodeCanvasView,
           let superview = canvas.superview,
           let hit = canvas.hitTest(superview.convert(event.locationInWindow, from: nil)),
           let node = canvas.node(containing: hit) {
            canvas.select(node: node)
        }
        super.sendEvent(event)
    }
}

// MARK: - Toggle

/// The SuperNode switch in the top-right corner of terminal windows and the
/// SuperNode window.
struct SuperNodeToggle: View {
    /// Whether this toggle is in the SuperNode window, where it's on.
    let isCanvas: Bool
    weak var window: NSWindow?

    var body: some View {
        Toggle(isOn: Binding(
            get: { isCanvas },
            set: { SuperNodeController.shared.setActive($0, from: window) }
        )) {
            HStack(spacing: 4) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("SuperNode")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isCanvas ? .primary : .secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help(isCanvas ? "Turn off SuperNode mode (⌃⌘N)" : "Turn on SuperNode mode (⌃⌘N)")
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
    }
}

extension TerminalWindow {
    /// Adds the SuperNode switch to the right of the titlebar.
    func addSuperNodeAccessory() {
        guard styleMask.contains(.titled) else { return }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = NonDraggableHostingView(rootView: SuperNodeToggle(isCanvas: false, window: self))
        addTitlebarAccessoryViewController(accessory)
        accessory.view.translatesAutoresizingMaskIntoConstraints = false
    }
}
