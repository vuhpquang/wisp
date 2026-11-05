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

    private static let frameName = "WispSuperNodeWindow"

    /// Each project has its own canvas. Open canvases stay in the window,
    /// hidden, so their terminals keep running and notifications can find them.
    @Published private(set) var projects: [SuperNodeProject] = []
    @Published private(set) var currentProjectID: UUID?
    private var canvases: [UUID: SuperNodeCanvasView] = [:]
    private let container = SuperNodeContainerView()
    private var loaded = false

    /// The canvas of the current project.
    var canvas: SuperNodeCanvasView? {
        currentProjectID.flatMap { canvases[$0] }
    }

    var currentProject: SuperNodeProject? {
        projects.first { $0.id == currentProjectID }
    }

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
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 320)
        window.collectionBehavior.insert(.fullScreenPrimary)
        // The SuperNode window keeps its own size and place, apart from
        // terminal windows; the first time it nearly fills the screen.
        if !window.setFrameUsingName(Self.frameName), let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.04, dy: screen.visibleFrame.height * 0.04), display: false)
        }
        window.setFrameAutosaveName(Self.frameName)
        super.init(window: window)
        window.delegate = self

        let toggle = NSTitlebarAccessoryViewController()
        toggle.layoutAttribute = .right
        toggle.view = NonDraggableHostingView(rootView: SuperNodeToggle(isCanvas: true, window: window))
        window.addTitlebarAccessoryViewController(toggle)
        toggle.view.translatesAutoresizingMaskIntoConstraints = false

        let projectMenu = NSTitlebarAccessoryViewController()
        projectMenu.layoutAttribute = .left
        projectMenu.view = NonDraggableHostingView(rootView: SuperNodeProjectMenu(controller: self))
        window.addTitlebarAccessoryViewController(projectMenu)
        projectMenu.view.translatesAutoresizingMaskIntoConstraints = false

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
    /// toggle was used in, shown again when SuperNode is turned off.
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
        }

        if !loaded {
            loaded = true
            window.contentView = container
            window.backgroundColor = NSColor(ghostty.config.backgroundColor)
            let index = SuperNodeStore.loadIndex()
            projects = index.projects
            SuperNodeHookCenter.shared.onEvent = { [weak self] event in self?.route(event) }
            SuperNodeHookCenter.shared.start()
            // `supernode` commands go to the project they name, or the current one.
            SuperNodeCommandCenter.shared.canvasFor = { [weak self] project in
                guard let self else { return nil }
                if let id = UUID(uuidString: project), let canvas = self.canvases[id] { return canvas }
                return self.canvas
            }
            SuperNodeCommandCenter.shared.start()
            switchTo(index.current.flatMap { id in index.projects.contains { $0.id == id } ? id : nil } ?? index.projects[0].id)
            // Sessions whose node is in no project are left over; end them.
            if SuperNodeTmux.executable != nil {
                SuperNodeTmux.removeOrphans(keeping: SuperNodeStore.allNodeIDs(in: index))
            }
        }

        isActive = true
        window.makeKeyAndOrderFront(nil)
        canvas?.setRefreshing(true)
        if let canvas, canvas.window?.firstResponder === window {
            window.makeFirstResponder(canvas)
        }
    }

    // MARK: Projects

    /// Shows a project's canvas, opening it the first time.
    func switchTo(_ id: UUID) {
        guard let ghostty, projects.contains(where: { $0.id == id }) else { return }
        if let current = canvas, currentProjectID != id {
            current.save()
            current.setRefreshing(false)
            current.isHidden = true
        }
        let canvas: SuperNodeCanvasView
        if let open = canvases[id] {
            canvas = open
        } else {
            canvas = SuperNodeCanvasView(ghostty: ghostty, projectID: id)
            canvas.frame = container.bounds
            canvas.autoresizingMask = [.width, .height]
            container.addSubview(canvas)
            canvases[id] = canvas
        }
        canvas.isHidden = false
        currentProjectID = id
        window?.title = "SuperNode – " + (currentProject?.name ?? "")
        saveIndex()
        if isActive { canvas.setRefreshing(true) }
        window?.makeFirstResponder(canvas)
    }

    func newProject() {
        promptName(title: "New Project", value: "") { [weak self] name in
            self?.createProject(named: name)
        }
    }

    func createProject(named name: String) {
        let project = SuperNodeProject(name: name)
        projects.append(project)
        switchTo(project.id)
    }

    func renameProject() {
        guard let project = currentProject else { return }
        promptName(title: "Rename Project", value: project.name) { [weak self] name in
            guard let self, let index = self.projects.firstIndex(where: { $0.id == project.id }) else { return }
            self.projects[index].name = name
            self.window?.title = "SuperNode – " + name
            self.saveIndex()
        }
    }

    /// Deletes the current project, closing its nodes and ending their sessions.
    func deleteProject() {
        guard let project = currentProject, projects.count > 1, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the project \(project.name)?"
        alert.informativeText = "Its canvas is deleted, and the terminals and agents on it are closed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let canvas = self.canvases[project.id] ?? self.canvas
            canvas?.closeAllNodes()
            canvas?.setRefreshing(false)
            canvas?.removeFromSuperview()
            self.canvases[project.id] = nil
            self.projects.removeAll { $0.id == project.id }
            SuperNodeStore.delete(project.id)
            self.currentProjectID = nil
            self.switchTo(self.projects[0].id)
        }
    }

    private func saveIndex() {
        SuperNodeStore.saveIndex(SuperNodeProjectIndex(projects: projects, current: currentProjectID))
    }

    private func promptName(title: String, value: String, completion: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        field.placeholderString = "Project name"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            completion(name)
        }
    }

    /// The open canvas a terminal belongs to.
    private func canvas(containing surface: Ghostty.SurfaceView) -> SuperNodeCanvasView? {
        canvases.values.first { $0.contains(surface) }
    }

    /// A hook event goes to the canvas with its node. A permission request
    /// for a project that isn't open is left to Claude's own prompt.
    private func route(_ event: SuperNodeHookEvent) {
        if let canvas = canvases.values.first(where: { $0.node(event.node) != nil }) {
            canvas.handle(event)
        } else if event.name == "PermissionRequest" {
            SuperNodeHooks.answer(event.id, with: "pass")
        }
    }

    /// Shows the project a terminal is in, as when a notification about it is clicked.
    func reveal(_ surface: Ghostty.SurfaceView) {
        guard let owner = canvases.first(where: { $0.value.contains(surface) })?.key, owner != currentProjectID else { return }
        switchTo(owner)
    }

    private func hide() {
        canvas?.save()
        canvas?.setRefreshing(false)
        isActive = false
        window?.orderOut(nil)
        showTerminalWindow()
    }

    /// Brings back the terminal window SuperNode was opened from, or any
    /// terminal window, or a new one if there are none left.
    private func showTerminalWindow() {
        if let returnWindow, returnWindow.windowController is BaseTerminalController {
            returnWindow.makeKeyAndOrderFront(nil)
        } else if let window = TerminalController.all.compactMap(\.window).first {
            window.makeKeyAndOrderFront(nil)
        } else if let ghostty {
            _ = TerminalController.newWindow(ghostty)
        }
    }

    // MARK: Force close

    /// The canvases of open projects, for the Process Monitor.
    var openCanvases: [SuperNodeCanvasView] { Array(canvases.values) }

    enum ForceCloseMode {
        /// Kills every process; canvases, notes and boards stay.
        case processes
        /// Kills every process and deletes every project.
        case everything
    }

    /// Asks before force closing, showing what SuperNode uses when known.
    func confirmForceClose(usage: SuperNodeUsage?, in sheetWindow: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Force close SuperNode?"
        var text = "Every terminal, agent, chat and web page in SuperNode is killed at once, without saving their work."
        if let usage, usage.processes > 0 {
            text = "SuperNode runs \(usage.processes) processes using "
                + "\(ByteCountFormatter.string(fromByteCount: Int64(usage.memory), countStyle: .memory)) of memory "
                + "and \(String(format: "%.0f", usage.cpu))% CPU.\n\n" + text
        }
        text += "\n\nKill Processes keeps your canvases; agents come back as plain shells. "
            + "Kill & Delete Everything also deletes every project, note, board and chat."
        alert.informativeText = text
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Kill Processes")
        alert.addButton(withTitle: "Kill & Delete Everything")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.forceClose(.processes)
            case .alertSecondButtonReturn: self?.forceClose(.everything)
            default: break
            }
        }
        if let sheetWindow {
            alert.beginSheetModal(for: sheetWindow, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// Kills everything SuperNode runs: the tmux server and every process in
    /// it, chat processes, web pages, and terminals outside tmux.
    func forceClose(_ mode: ForceCloseMode) {
        // Gather processes while the views still know them.
        let parents = ProcessSampler.parents()
        let wisp = getpid()
        var targets: [pid_t] = []
        for root in SuperNodeUsageRoots.current(savedNodes: [:]).roots {
            targets += root.pids
            if var pid = root.foregroundPID {
                while let parent = parents[pid], parent != wisp, parent > 1 { pid = parent }
                if parents[pid] == wisp { targets += ProcessSampler.descendants(of: pid, parents: parents) }
            }
        }

        var nodes = Set(canvases.values.flatMap { $0.nodeViews.map(\.item.id) })
        if let index = SuperNodeStore.savedIndex() { nodes.formUnion(SuperNodeStore.allNodeIDs(in: index)) }

        if mode == .processes {
            // Agents come back as shells, so reopening doesn't start them all again.
            for canvas in canvases.values {
                for node in canvas.nodeViews where node.item.kind == .agent {
                    node.item.suspended = true
                }
                canvas.save()
            }
            for project in SuperNodeStore.savedIndex()?.projects ?? [] where canvases[project.id] == nil {
                var document = SuperNodeStore.load(project.id)
                guard document.nodes.contains(where: { $0.kind == .agent }) else { continue }
                for index in document.nodes.indices where document.nodes[index].kind == .agent {
                    document.nodes[index].suspended = true
                }
                SuperNodeStore.save(document, project: project.id)
            }
        }

        if isActive {
            isActive = false
            window?.orderOut(nil)
            showTerminalWindow()
        }
        for canvas in canvases.values {
            canvas.discard()
            canvas.removeFromSuperview()
        }
        canvases = [:]
        projects = []
        currentProjectID = nil
        loaded = false
        window?.title = "SuperNode"

        let found = targets
        DispatchQueue.global(qos: .userInitiated).async {
            var targets = found
            // Kill the processes in tmux first: some agents outlive a hangup.
            if let server = SuperNodeUsage.tmuxProcesses().server {
                targets += ProcessSampler.descendants(of: server, parents: ProcessSampler.parents()).filter { $0 != server }
            }
            for pid in Set(targets) { ProcessSampler.signal(pid, SIGKILL) }
            if SuperNodeTmux.executable != nil { SuperNodeTmux.run(["kill-server"]) }
            SuperNodeStore.removeRuntimeFiles(of: nodes)
            if mode == .everything { SuperNodeStore.deleteEverything() }
        }
    }

    // MARK: NSWindowDelegate

    // Closing the window turns SuperNode off; its terminals keep running.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    // Edit > Undo and Redo work on the current canvas.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        canvas?.undoManager
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
        guard let surface = notification.object as? Ghostty.SurfaceView, let canvas = canvas(containing: surface) else { return }
        let processAlive = (notification.userInfo?["process_alive"] as? Bool) ?? false
        canvas.close(surface: surface, confirm: processAlive)
    }

    @objc private func surfaceDidRequestSplit(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView, let canvas = canvas(containing: surface) else { return }
        guard let direction = notification.userInfo?["direction"] as? ghostty_action_split_direction_e else { return }
        let config = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration
        let newDirection: SplitTree<Ghostty.SurfaceView>.NewDirection
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT: newDirection = .left
        case GHOSTTY_SPLIT_DIRECTION_UP: newDirection = .up
        case GHOSTTY_SPLIT_DIRECTION_DOWN: newDirection = .down
        default: newDirection = .right
        }
        canvas.split(surface, direction: newDirection, config: config)
    }

    @objc private func surfaceDidRequestTab(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView, let canvas = canvas(containing: surface) else { return }
        let config = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration
        canvas.newTerminal(near: surface, config: config)
    }

    @objc private func surfaceDidRequestCloseTab(_ notification: Notification) {
        guard let surface = notification.object as? Ghostty.SurfaceView, let canvas = canvas(containing: surface) else { return }
        canvas.close(surface: surface, confirm: true)
    }

    @objc private func appWillTerminate(_ notification: Notification) {
        for canvas in canvases.values {
            canvas.save()
            canvas.saveScrollback(waiting: true)
        }
    }

    /// A terminal on any open canvas, for notifications to find when clicked.
    func surface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        for canvas in canvases.values {
            if let terminal = canvas.terminalNodes.first(where: { $0.surface.id == uuid }) { return terminal.surface }
        }
        return nil
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
    // ⌘⇧B switches between the canvas and the board, ⌘K opens the command
    // palette, and ⌘Z undoes canvas changes, even from a terminal. Text being
    // edited keeps its own ⌘Z through the canvas's shared history.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if let canvas = SuperNodeController.shared.canvas, !(firstResponder is NSTextView) {
            if flags == .command, key == "z", canvas.undoManager?.canUndo == true {
                canvas.undoManager?.undo()
                return true
            }
            if flags == [.command, .shift], key == "z", canvas.undoManager?.canRedo == true {
                canvas.undoManager?.redo()
                return true
            }
        }
        if flags == .command, key == "k", let canvas = SuperNodeController.shared.canvas {
            canvas.showPalette()
            return true
        }
        if flags == .command, key == "j", let canvas = SuperNodeController.shared.canvas {
            canvas.toggleChat()
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "b",
           let canvas = SuperNodeController.shared.canvas {
            canvas.toggleBoard()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        // A terminal in another project, such as from a notification, shows that project first.
        if let surface = responder as? Ghostty.SurfaceView { SuperNodeController.shared.reveal(surface) }
        let result = super.makeFirstResponder(responder)
        if result, let surface = responder as? Ghostty.SurfaceView,
           let canvas = SuperNodeController.shared.canvas {
            canvas.surfaceDidFocus(surface)
        }
        return result
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           let canvas = SuperNodeController.shared.canvas,
           let superview = canvas.superview,
           let hit = canvas.hitTest(superview.convert(event.locationInWindow, from: nil)),
           let node = canvas.node(containing: hit) {
            canvas.select(node: node)
        }
        super.sendEvent(event)
    }
}

// MARK: - Projects

/// Holds the canvases of open projects; only the current one is visible.
final class SuperNodeContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// The project menu at the left of the SuperNode titlebar.
struct SuperNodeProjectMenu: View {
    @ObservedObject var controller: SuperNodeController

    var body: some View {
        Menu {
            ForEach(controller.projects) { project in
                Button {
                    controller.switchTo(project.id)
                } label: {
                    if project.id == controller.currentProjectID {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
            Divider()
            Button("New Project…") { controller.newProject() }
            Button("Rename Project…") { controller.renameProject() }
            Button("Delete Project…") { controller.deleteProject() }
                .disabled(controller.projects.count <= 1)
            Divider()
            Button("Resource Usage…") { ProcessMonitorWindowController.shared.show(tab: .superNode) }
            Button("Force Close SuperNode…") {
                controller.confirmForceClose(usage: ProcessMonitorWindowController.shared.latestSuperNodeUsage, in: controller.window)
            }
        } label: {
            // One Text: a borderless menu shows only the first view of its label.
            (Text("SuperNode  /  ").foregroundColor(.secondary) + Text(controller.currentProject?.name ?? ""))
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.leading, 8)
        .frame(maxHeight: .infinity)
        .help("Switch project")
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
