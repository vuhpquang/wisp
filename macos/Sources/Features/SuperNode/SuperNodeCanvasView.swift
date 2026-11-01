import AppKit
import Combine
import SwiftUI

/// A terminal surface that lives on the zoomable canvas.
///
/// The canvas zooms by scaling the bounds of the view that holds the nodes,
/// which also scales `convertToBacking`. Ghostty sizes its grid from
/// `convertToBacking` but renders at the layer's own (unscaled) size, so the
/// two would disagree at any zoom other than 100%. Converting with only the
/// window's scale keeps the terminal the same size in cells at every zoom.
final class SuperNodeSurfaceView: Ghostty.SurfaceView {
    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? 1
    }

    override func convertToBacking(_ size: NSSize) -> NSSize {
        NSSize(width: size.width * backingScale, height: size.height * backingScale)
    }

    override func convertToBacking(_ rect: NSRect) -> NSRect {
        let scale = backingScale
        return NSRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }
}

/// State the SwiftUI dock at the bottom of the canvas shows.
final class SuperNodeCanvasModel: ObservableObject {
    @Published var zoom: CGFloat = 1
    @Published var isEmpty = true
}

/// Holds the node views. Its bounds are scaled and offset to pan and zoom.
private final class SuperNodeWorldView: NSView {
    override var isFlipped: Bool { true }

    // Empty space falls through to the canvas, which pans and draws edges.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// The infinite canvas: pans, zooms, draws the grid and the connections
/// between nodes, and owns the node views.
final class SuperNodeCanvasView: NSView {
    let ghostty: Ghostty.App
    let model = SuperNodeCanvasModel()

    private(set) var document: SuperNodeDocument
    private let world = SuperNodeWorldView()
    private(set) var nodeViews: [SuperNodeNodeView] = []
    private var dock: NSView!
    private var emptyHint: NSView!

    private var selectedEdge: UUID?
    private var linkDrag: (from: SuperNodeNodeView, to: CGPoint)?
    private var panStart: (point: NSPoint, origin: CGPoint)?
    private var movingGroupMembers: [SuperNodeNodeView] = []
    private var nextZOrder = 0
    private var saveWork: DispatchWorkItem?
    private var diffTimer: Timer?

    static let zoomRange: ClosedRange<CGFloat> = 0.15...1.5

    init(ghostty: Ghostty.App, document: SuperNodeDocument) {
        self.ghostty = ghostty
        self.document = document
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        wantsLayer = true
        addSubview(world)

        let hint = SuperNodePassthroughHostingView(rootView: SuperNodeEmptyHint())
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        emptyHint = hint

        let dock = NSHostingView(rootView: SuperNodeDock(canvas: self, model: model))
        dock.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dock)
        self.dock = dock

        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            dock.centerXAnchor.constraint(equalTo: centerXAnchor),
            dock.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])

        for item in document.nodes {
            addNodeView(for: item, restoring: true)
        }
        model.zoom = document.zoom
        updateEmptyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        applyTransform()
    }

    // MARK: Viewport

    var zoom: CGFloat { document.zoom }

    private func applyTransform() {
        world.frame = bounds
        world.bounds = NSRect(
            origin: document.origin,
            size: NSSize(width: bounds.width / zoom, height: bounds.height / zoom))
        model.zoom = zoom
        needsDisplay = true
    }

    /// The point in world coordinates under the mouse for an event.
    func worldPoint(for event: NSEvent) -> CGPoint {
        world.convert(event.locationInWindow, from: nil)
    }

    private func worldPoint(fromCanvas point: NSPoint) -> CGPoint {
        world.convert(point, from: self)
    }

    private func canvasPoint(fromWorld point: CGPoint) -> NSPoint {
        convert(point, from: world)
    }

    /// The world point at the center of the visible canvas.
    var visibleCenter: CGPoint {
        worldPoint(fromCanvas: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    func setZoom(_ newZoom: CGFloat, anchor: NSPoint? = nil) {
        let anchor = anchor ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let fixed = worldPoint(fromCanvas: anchor)
        let zoom = min(max(newZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        document.zoom = zoom
        document.origin = CGPoint(x: fixed.x - anchor.x / zoom, y: fixed.y - anchor.y / zoom)
        applyTransform()
        scheduleSave()
    }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }

    /// Zooms and pans so every node is visible.
    func zoomToFit() {
        let frames = nodeViews.map(\.item.frame)
        guard var rect = frames.first else {
            document.origin = .zero
            setZoom(1)
            return
        }
        for frame in frames.dropFirst() { rect = rect.union(frame) }
        zoom(to: rect)
    }

    private func zoom(to rect: CGRect) {
        let rect = rect.insetBy(dx: -60, dy: -60)
        let available = NSSize(width: bounds.width, height: bounds.height - 70)
        let zoom = min(
            max(min(available.width / rect.width, available.height / rect.height), Self.zoomRange.lowerBound),
            1)
        document.zoom = zoom
        document.origin = CGPoint(
            x: rect.midX - bounds.width / 2 / zoom,
            y: rect.midY - (bounds.height - 70) / 2 / zoom)
        applyTransform()
        scheduleSave()
    }

    private func pan(by delta: CGSize) {
        document.origin.x -= delta.width / zoom
        document.origin.y -= delta.height / zoom
        applyTransform()
        scheduleSave()
    }

    override func scrollWheel(with event: NSEvent) {
        // Scrolling over a terminal scrolls the terminal; over the canvas it
        // pans. Holding ⌘ zooms, like a mouse wheel in most canvas apps.
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
            setZoom(zoom * (1 + delta), anchor: convert(event.locationInWindow, from: nil))
            return
        }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        pan(by: CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale))
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        setZoom(zoom < 0.9 ? 1 : 0.5, anchor: convert(event.locationInWindow, from: nil))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(ghostty.config.backgroundColor).blended(withFraction: 0.35, of: .black)?.setFill()
        dirtyRect.fill()
        drawGrid(in: dirtyRect)
        drawEdges()
    }

    private func drawGrid(in rect: NSRect) {
        var spacing: CGFloat = 24 * zoom
        while spacing < 12 { spacing *= 2 }
        let origin = canvasPoint(fromWorld: .zero)
        let startX = origin.x.truncatingRemainder(dividingBy: spacing) - spacing
        let startY = origin.y.truncatingRemainder(dividingBy: spacing) - spacing
        NSColor.white.withAlphaComponent(0.08).setFill()
        let size: CGFloat = zoom > 0.5 ? 2 : 1.5
        var x = startX
        while x < rect.maxX {
            if x >= rect.minX - size {
                var y = startY
                while y < rect.maxY {
                    if y >= rect.minY - size {
                        NSRect(x: x, y: y, width: size, height: size).fill()
                    }
                    y += spacing
                }
            }
            x += spacing
        }
    }

    /// The curve of a connection in canvas coordinates, and where its label goes.
    private func path(from source: CGRect, to target: CGRect) -> (path: NSBezierPath, mid: NSPoint, end: NSPoint, direction: CGVector) {
        let a = NSRect(origin: canvasPoint(fromWorld: source.origin), size: CGSize(width: source.width * zoom, height: source.height * zoom))
        let b = NSRect(origin: canvasPoint(fromWorld: target.origin), size: CGSize(width: target.width * zoom, height: target.height * zoom))

        // Leave from the sides that face each other.
        let dx = b.midX - a.midX
        let dy = b.midY - a.midY
        let start: NSPoint, end: NSPoint, out: CGVector
        if abs(dx) * a.height >= abs(dy) * a.width {
            start = NSPoint(x: dx >= 0 ? a.maxX : a.minX, y: a.midY)
            end = NSPoint(x: dx >= 0 ? b.minX : b.maxX, y: b.midY)
            out = CGVector(dx: dx >= 0 ? 1 : -1, dy: 0)
        } else {
            start = NSPoint(x: a.midX, y: dy >= 0 ? a.maxY : a.minY)
            end = NSPoint(x: b.midX, y: dy >= 0 ? b.minY : b.maxY)
            out = CGVector(dx: 0, dy: dy >= 0 ? 1 : -1)
        }
        let reach = max(40, min(160, hypot(end.x - start.x, end.y - start.y) / 2))
        let c1 = NSPoint(x: start.x + out.dx * reach, y: start.y + out.dy * reach)
        let c2 = NSPoint(x: end.x - out.dx * reach, y: end.y - out.dy * reach)
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
        let mid = NSPoint(
            x: 0.125 * start.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * end.x,
            y: 0.125 * start.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * end.y)
        return (path, mid, end, out)
    }

    private func edgeColor(_ edge: SuperNodeEdge) -> NSColor {
        guard let from = node(edge.from), let to = node(edge.to) else { return .secondaryLabelColor }
        if from.item.kind == .note { return .systemYellow }
        if to.item.kind == .diff { return .systemGreen }
        if from.item.kind == .agent || to.item.kind == .agent { return .systemPurple }
        return .controlAccentColor
    }

    private func drawEdges() {
        for edge in document.edges {
            guard let from = node(edge.from), let to = node(edge.to) else { continue }
            let (path, mid, end, direction) = path(from: from.item.frame, to: to.item.frame)
            let selected = edge.id == selectedEdge
            let color = edgeColor(edge)
            color.withAlphaComponent(selected ? 1 : 0.75).setStroke()
            path.lineWidth = selected ? 3 : 2
            path.stroke()
            drawArrow(at: end, direction: direction, color: color)
            if let label = edge.label, !label.isEmpty {
                drawLabel(label, at: mid, color: color)
            }
        }

        if let linkDrag {
            let target = CGRect(origin: linkDrag.to, size: CGSize(width: 1, height: 1))
            let (path, _, _, _) = path(from: linkDrag.from.item.frame, to: target)
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()
        }
    }

    private func drawArrow(at point: NSPoint, direction: CGVector, color: NSColor) {
        let size: CGFloat = 8
        let back = NSPoint(x: point.x - direction.dx * size, y: point.y - direction.dy * size)
        let side = CGVector(dx: -direction.dy * size * 0.6, dy: direction.dx * size * 0.6)
        let arrow = NSBezierPath()
        arrow.move(to: point)
        arrow.line(to: NSPoint(x: back.x + side.dx, y: back.y + side.dy))
        arrow.line(to: NSPoint(x: back.x - side.dx, y: back.y - side.dy))
        arrow.close()
        color.setFill()
        arrow.fill()
    }

    private func drawLabel(_ label: String, at point: NSPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        let rect = NSRect(x: point.x - size.width / 2 - 7, y: point.y - size.height / 2 - 3, width: size.width + 14, height: size.height + 6)
        color.blended(withFraction: 0.45, of: .black)?.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        text.draw(at: NSPoint(x: rect.minX + 7, y: rect.minY + 3))
    }

    /// The distance from a point to a curve, measured along a flattened copy.
    private func distance(from point: NSPoint, to path: NSBezierPath) -> CGFloat {
        let flat = path.flattened
        var points = [NSPoint](repeating: .zero, count: 3)
        var previous: NSPoint?
        var best = CGFloat.greatestFiniteMagnitude
        for index in 0..<flat.elementCount {
            flat.element(at: index, associatedPoints: &points)
            let current = points[0]
            if let previous {
                let dx = current.x - previous.x, dy = current.y - previous.y
                let length = dx * dx + dy * dy
                let t = length == 0 ? 0 : max(0, min(1, ((point.x - previous.x) * dx + (point.y - previous.y) * dy) / length))
                best = min(best, hypot(point.x - (previous.x + t * dx), point.y - (previous.y + t * dy)))
            }
            previous = current
        }
        return best
    }

    private func edge(at point: NSPoint) -> SuperNodeEdge? {
        for edge in document.edges.reversed() {
            guard let from = node(edge.from), let to = node(edge.to) else { continue }
            let (path, _, _, _) = path(from: from.item.frame, to: to.item.frame)
            if distance(from: point, to: path) < 6 { return edge }
        }
        return nil
    }

    // MARK: Mouse on the canvas

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        select(node: nil)

        if let edge = edge(at: point) {
            selectedEdge = edge.id
            needsDisplay = true
            if event.clickCount == 2 { renameEdge(edge.id) }
            return
        }
        selectedEdge = nil
        needsDisplay = true

        if event.clickCount == 2 {
            addNode(.terminal, at: worldPoint(for: event))
            return
        }
        panStart = (point, document.origin)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        document.origin = CGPoint(
            x: panStart.origin.x - (point.x - panStart.point.x) / zoom,
            y: panStart.origin.y - (point.y - panStart.point.y) / zoom)
        applyTransform()
    }

    override func mouseUp(with event: NSEvent) {
        guard panStart != nil else { return }
        panStart = nil
        NSCursor.pop()
        scheduleSave()
    }

    override func keyDown(with event: NSEvent) {
        // Delete removes the selected connection.
        if let selectedEdge, event.keyCode == 51 || event.keyCode == 117 {
            removeEdge(selectedEdge)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let edge = edge(at: point) {
            selectedEdge = edge.id
            needsDisplay = true
            return menu(for: edge)
        }
        return addMenu(at: worldPoint(for: event))
    }

    /// The menu of nodes to add at a world point.
    func addMenu(at point: CGPoint?) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = SuperNodeMenuItem(title: title, handler: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }
        menu.addItem(item("New Terminal", "terminal") { [weak self] in self?.addNode(.terminal, at: point) })
        for agent in SuperNodeAgent.allCases {
            menu.addItem(item("New \(agent.name)", "sparkles") { [weak self] in
                self?.addNode(.agent, at: point, agent: agent)
            })
        }
        menu.addItem(.separator())
        menu.addItem(item("New Note", "note.text") { [weak self] in self?.addNode(.note, at: point) })
        menu.addItem(item("New Diff…", "plusminus") { [weak self] in self?.addDiff(at: point) })
        menu.addItem(item("New Group", "square.dashed") { [weak self] in self?.addNode(.group, at: point) })
        menu.addItem(.separator())
        menu.addItem(item("Zoom to Fit", "arrow.up.left.and.arrow.down.right") { [weak self] in self?.zoomToFit() })
        return menu
    }

    // MARK: Nodes

    func node(_ id: UUID) -> SuperNodeNodeView? {
        nodeViews.first { $0.item.id == id }
    }

    func node(containing view: NSView) -> SuperNodeNodeView? {
        var current: NSView? = view
        while let view = current {
            if let node = view as? SuperNodeNodeView, node.canvas === self { return node }
            current = view.superview
        }
        return nil
    }

    var terminalNodes: [SuperNodeTerminalView] {
        nodeViews.compactMap { $0 as? SuperNodeTerminalView }
    }

    /// Adds a node centered on `point`, or the middle of the canvas.
    @discardableResult
    func addNode(
        _ kind: SuperNodeItem.Kind,
        at point: CGPoint? = nil,
        agent: SuperNodeAgent? = nil,
        directory: String? = nil,
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        frame: CGRect? = nil
    ) -> SuperNodeNodeView? {
        let size = kind.defaultSize
        let center = point ?? visibleCenter
        var item = SuperNodeItem(
            kind: kind,
            frame: frame ?? CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
        item.agent = agent
        item.directory = directory ?? baseConfig?.workingDirectory ?? defaultDirectory(near: item.frame)
        if kind == .group { item.title = "Group" }

        let view = addNodeView(for: item, restoring: false, baseConfig: baseConfig)
        if let view {
            select(node: view)
            if let terminal = view as? SuperNodeTerminalView {
                DispatchQueue.main.async { [weak self] in
                    self?.window?.makeFirstResponder(terminal.surface)
                }
            }
        }
        documentDidChange()
        return view
    }

    /// New terminals start in the folder of the group they're dropped in.
    private func defaultDirectory(near frame: CGRect) -> String? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let group = nodeViews.last { $0.item.kind == .group && $0.item.frame.contains(center) }
        let inside = group.map { nodes(inside: $0) } ?? []
        return inside.compactMap { ($0 as? SuperNodeTerminalView)?.directory }.first
    }

    @discardableResult
    private func addNodeView(
        for item: SuperNodeItem,
        restoring: Bool,
        baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> SuperNodeNodeView? {
        let view: SuperNodeNodeView
        switch item.kind {
        case .terminal, .agent:
            guard let app = ghostty.app else { return nil }
            var config = baseConfig ?? Ghostty.SurfaceConfiguration()
            if let directory = item.directory { config.workingDirectory = directory }
            if item.kind == .agent, let agent = item.agent {
                // Typed into the shell rather than run as the command, so the
                // shell stays when the agent exits.
                config.initialInput = (restoring ? agent.resumeCommand : agent.command) + "\n"
            }
            let surface = SuperNodeSurfaceView(app, baseConfig: config)
            view = SuperNodeTerminalView(item: item, surface: surface, ghostty: ghostty)
        case .note:
            view = SuperNodeNoteView(item: item)
        case .diff:
            view = SuperNodeDiffView(item: item)
        case .group:
            view = SuperNodeGroupView(item: item)
        }

        view.canvas = self
        if view.item.kind != .group {
            nextZOrder += 1
            view.zOrder = nextZOrder
        }
        nodeViews.append(view)
        world.addSubview(view)
        sortNodes()
        view.refreshHeader()
        (view as? SuperNodeDiffView)?.reload()
        updateEmptyState()
        return view
    }

    private func sortNodes() {
        world.sortSubviews({ a, b, _ in
            let za = (a as? SuperNodeNodeView)?.zOrder ?? 0
            let zb = (b as? SuperNodeNodeView)?.zOrder ?? 0
            return za < zb ? .orderedAscending : za > zb ? .orderedDescending : .orderedSame
        }, context: nil)
    }

    /// Selects a node and brings it to the front.
    func select(node: SuperNodeNodeView?) {
        for view in nodeViews where view !== node { view.isSelected = false }
        guard let node else { return }
        node.isSelected = true
        if selectedEdge != nil {
            selectedEdge = nil
            needsDisplay = true
        }
        guard node.item.kind != .group, node.zOrder != nextZOrder else { return }
        nextZOrder += 1
        node.zOrder = nextZOrder
        sortNodes()
    }

    /// Nodes whose center is inside a group.
    func nodes(inside group: SuperNodeNodeView) -> [SuperNodeNodeView] {
        nodeViews.filter {
            $0 !== group && $0.item.kind != .group
                && group.item.frame.contains(CGPoint(x: $0.item.frame.midX, y: $0.item.frame.midY))
        }
    }

    func beginMoving(_ node: SuperNodeNodeView) {
        select(node: node)
        movingGroupMembers = node.item.kind == .group ? nodes(inside: node) : []
    }

    func move(_ node: SuperNodeNodeView, by delta: CGSize) {
        for view in [node] + movingGroupMembers {
            view.item.frame = view.item.frame.offsetBy(dx: delta.width, dy: delta.height)
        }
        needsDisplay = true
    }

    func endMoving(_ node: SuperNodeNodeView) {
        movingGroupMembers = []
        // Group headers count the nodes inside them.
        for group in nodeViews where group.item.kind == .group { group.refreshHeader() }
        documentDidChange()
    }

    func resize(_ node: SuperNodeNodeView, to size: CGSize) {
        let minimum = node.item.kind.minimumSize
        node.item.frame.size = CGSize(width: max(minimum.width, size.width), height: max(minimum.height, size.height))
        needsDisplay = true
    }

    /// Closes a node, asking first if it's running something.
    func closeNode(_ node: SuperNodeNodeView, confirm: Bool = true) {
        if confirm && node.needsConfirmClose {
            let alert = NSAlert()
            alert.messageText = "Close \(node.displayTitle)?"
            alert.informativeText = "The process running in this node will be terminated."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.closeNode(node, confirm: false)
            }
            return
        }

        node.tearDown()
        node.removeFromSuperview()
        nodeViews.removeAll { $0 === node }
        document.edges.removeAll { $0.from == node.item.id || $0.to == node.item.id }
        updateEmptyState()
        needsDisplay = true
        documentDidChange()
    }

    func renameNode(_ node: SuperNodeNodeView) {
        prompt(title: "Rename Node", message: nil, value: node.displayTitle) { [weak node, weak self] name in
            guard let node else { return }
            node.item.title = name.isEmpty ? nil : name
            self?.documentDidChange()
        }
    }

    func menu(for node: SuperNodeNodeView) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(SuperNodeMenuItem(title: "Rename…") { [weak self] in self?.renameNode(node) })

        let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for color in SuperNodeColor.allCases {
            let item = SuperNodeMenuItem(title: color.name) { [weak self] in
                node.item.color = color
                self?.needsDisplay = true
                self?.documentDidChange()
            }
            item.state = node.item.color == color ? .on : .off
            colorMenu.addItem(item)
        }
        colors.submenu = colorMenu
        menu.addItem(colors)

        if let terminal = node as? SuperNodeTerminalView {
            menu.addItem(.separator())
            menu.addItem(SuperNodeMenuItem(title: "Show Changes") { [weak self] in self?.openDiff(for: terminal) })
            menu.addItem(SuperNodeMenuItem(title: "New Note for This Node") { [weak self] in self?.addNote(for: terminal) })
            menu.addItem(SuperNodeMenuItem(title: "Open Folder in a New Tab") { [weak self] in self?.openInTab(terminal) })
        }
        if node.item.kind == .group {
            menu.addItem(.separator())
            menu.addItem(SuperNodeMenuItem(title: "New Terminal in Group") { [weak self] in
                self?.addNode(.terminal, at: CGPoint(x: node.item.frame.midX, y: node.item.frame.midY))
            })
            menu.addItem(SuperNodeMenuItem(title: "Fit Group to Nodes") { [weak self] in self?.fit(group: node) })
        }

        menu.addItem(.separator())
        menu.addItem(SuperNodeMenuItem(title: "Zoom to Node") { [weak self] in self?.zoom(to: node.item.frame) })
        menu.addItem(SuperNodeMenuItem(title: "Close Node") { [weak self] in self?.closeNode(node) })
        return menu
    }

    private func fit(group: SuperNodeNodeView) {
        let inside = nodes(inside: group)
        guard var rect = inside.first?.item.frame else { return }
        for node in inside.dropFirst() { rect = rect.union(node.item.frame) }
        group.item.frame = rect.insetBy(dx: -30, dy: -30).offsetBy(dx: 0, dy: -SuperNodeNodeView.headerHeight / 2)
        group.item.frame.size.height += SuperNodeNodeView.headerHeight
        needsDisplay = true
        documentDidChange()
    }

    /// Opens a new Wisp tab in the terminal's folder.
    private func openInTab(_ terminal: SuperNodeTerminalView) {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = terminal.directory
        SuperNodeController.shared.setActive(false)
        if let window = TerminalController.all.first?.window {
            _ = TerminalController.newTab(ghostty, from: window, withBaseConfig: config)
        } else {
            _ = TerminalController.newWindow(ghostty, withBaseConfig: config)
        }
    }

    // MARK: Diffs and notes

    func addDiff(at point: CGPoint?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Show Changes"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addNode(.diff, at: point, directory: url.path)
    }

    /// Opens a diff connected to a terminal, beside it, or selects the one
    /// that already is.
    func openDiff(for terminal: SuperNodeTerminalView) {
        if let existing = document.edges.first(where: { $0.from == terminal.item.id && node($0.to)?.item.kind == .diff }),
           let diff = node(existing.to) {
            select(node: diff)
            return
        }
        let size = SuperNodeItem.Kind.diff.defaultSize
        let frame = CGRect(
            x: terminal.item.frame.maxX + 80,
            y: terminal.item.frame.minY,
            width: size.width,
            height: max(size.height, terminal.item.frame.height))
        guard let diff = addNode(.diff, directory: terminal.directory, frame: frame) else { return }
        connect(terminal, to: diff, label: "changes")
    }

    private func addNote(for terminal: SuperNodeTerminalView) {
        let size = SuperNodeItem.Kind.note.defaultSize
        let frame = CGRect(
            x: terminal.item.frame.minX - size.width - 80,
            y: terminal.item.frame.minY,
            width: size.width,
            height: size.height)
        guard let note = addNode(.note, frame: frame) else { return }
        connect(note, to: terminal, label: "context")
    }

    /// The folder of the terminal connected into a diff node, if any.
    func sourceDirectory(for node: SuperNodeNodeView) -> String? {
        for edge in document.edges where edge.to == node.item.id {
            if let terminal = self.node(edge.from) as? SuperNodeTerminalView, let directory = terminal.directory {
                return directory
            }
        }
        for edge in document.edges where edge.from == node.item.id {
            if let terminal = self.node(edge.to) as? SuperNodeTerminalView, let directory = terminal.directory {
                return directory
            }
        }
        return nil
    }

    /// Removes connections from terminals into a node, used when a diff
    /// switches to a folder of its own.
    func disconnectSources(of node: SuperNodeNodeView) {
        document.edges.removeAll {
            ($0.to == node.item.id && self.node($0.from) is SuperNodeTerminalView)
                || ($0.from == node.item.id && self.node($0.to) is SuperNodeTerminalView)
        }
        needsDisplay = true
    }

    /// Pastes a note into every terminal it's connected to.
    func sendNote(_ note: SuperNodeNoteView) {
        let text = note.item.text ?? ""
        guard !text.isEmpty else { return }
        let targets = connectedTerminals(of: note)
        guard !targets.isEmpty else {
            NSSound.beep()
            return
        }
        for terminal in targets { paste(text, into: terminal) }
    }

    private func connectedTerminals(of node: SuperNodeNodeView) -> [SuperNodeTerminalView] {
        document.edges.compactMap { edge -> SuperNodeTerminalView? in
            if edge.from == node.item.id { return self.node(edge.to) as? SuperNodeTerminalView }
            if edge.to == node.item.id { return self.node(edge.from) as? SuperNodeTerminalView }
            return nil
        }
    }

    /// Pastes the recent output of one terminal into another, so an agent can
    /// see what the other terminal is doing.
    private func sendOutput(from source: SuperNodeTerminalView, to target: SuperNodeTerminalView) {
        var lines = source.surface.cachedScreenContents.get()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        let output = lines.suffix(200).joined(separator: "\n")
        paste("Output from \(source.displayTitle):\n```\n\(output)\n```\n", into: target)
    }

    /// Types text into a terminal as a paste, without pressing Return.
    private func paste(_ text: String, into terminal: SuperNodeTerminalView) {
        terminal.surface.surfaceModel?.sendText(text)
        select(node: terminal)
        window?.makeFirstResponder(terminal.surface)
    }

    // MARK: Connections

    func beginLink(from node: SuperNodeNodeView, event: NSEvent) {
        linkDrag = (node, worldPoint(for: event))
        needsDisplay = true
    }

    func updateLink(event: NSEvent) {
        guard linkDrag != nil else { return }
        linkDrag?.to = worldPoint(for: event)
        needsDisplay = true
    }

    func endLink(event: NSEvent) {
        guard let linkDrag else { return }
        self.linkDrag = nil
        needsDisplay = true
        let point = worldPoint(for: event)
        // Prefer the topmost node under the pointer; groups only if nothing else.
        let target = nodeViews
            .filter { $0 !== linkDrag.from && $0.item.frame.contains(point) }
            .max { $0.zOrder < $1.zOrder }
        guard let target else { return }
        connect(linkDrag.from, to: target)
    }

    func connect(_ from: SuperNodeNodeView, to: SuperNodeNodeView, label: String? = nil) {
        guard !document.edges.contains(where: {
            ($0.from == from.item.id && $0.to == to.item.id) || ($0.from == to.item.id && $0.to == from.item.id)
        }) else { return }
        document.edges.append(SuperNodeEdge(from: from.item.id, to: to.item.id, label: label))
        if let diff = to as? SuperNodeDiffView { diff.reload() }
        needsDisplay = true
        documentDidChange()
    }

    private func removeEdge(_ id: UUID) {
        document.edges.removeAll { $0.id == id }
        if selectedEdge == id { selectedEdge = nil }
        needsDisplay = true
        documentDidChange()
    }

    private func renameEdge(_ id: UUID) {
        guard let edge = document.edges.first(where: { $0.id == id }) else { return }
        prompt(title: "Label Connection", message: "Describe how these nodes relate.", value: edge.label ?? "") { [weak self] label in
            guard let self, let index = self.document.edges.firstIndex(where: { $0.id == id }) else { return }
            self.document.edges[index].label = label.isEmpty ? nil : label
            self.needsDisplay = true
            self.documentDidChange()
        }
    }

    private func menu(for edge: SuperNodeEdge) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(SuperNodeMenuItem(title: "Label…") { [weak self] in self?.renameEdge(edge.id) })

        let from = node(edge.from), to = node(edge.to)
        if let a = from as? SuperNodeTerminalView, let b = to as? SuperNodeTerminalView {
            menu.addItem(.separator())
            menu.addItem(SuperNodeMenuItem(title: "Send Output of \(a.displayTitle) to \(b.displayTitle)") { [weak self] in
                self?.sendOutput(from: a, to: b)
            })
            menu.addItem(SuperNodeMenuItem(title: "Send Output of \(b.displayTitle) to \(a.displayTitle)") { [weak self] in
                self?.sendOutput(from: b, to: a)
            })
        }
        if let note = (from as? SuperNodeNoteView) ?? (to as? SuperNodeNoteView),
           let terminal = (from as? SuperNodeTerminalView) ?? (to as? SuperNodeTerminalView) {
            menu.addItem(.separator())
            menu.addItem(SuperNodeMenuItem(title: "Send Note to \(terminal.displayTitle)") { [weak self] in
                guard let text = note.item.text, !text.isEmpty else { return }
                self?.paste(text, into: terminal)
            })
        }

        menu.addItem(.separator())
        menu.addItem(SuperNodeMenuItem(title: "Reverse Direction") { [weak self] in
            guard let self, let index = self.document.edges.firstIndex(where: { $0.id == edge.id }) else { return }
            let edge = self.document.edges[index]
            self.document.edges[index].from = edge.to
            self.document.edges[index].to = edge.from
            self.needsDisplay = true
            self.documentDidChange()
        })
        menu.addItem(SuperNodeMenuItem(title: "Delete Connection") { [weak self] in self?.removeEdge(edge.id) })
        return menu
    }

    // MARK: Terminal events

    /// A terminal in a node asked for a split: open a new terminal beside it
    /// and connect the two.
    func split(_ surface: Ghostty.SurfaceView, direction: SplitTree<Ghostty.SurfaceView>.NewDirection, config: Ghostty.SurfaceConfiguration?) {
        guard let source = terminalNodes.first(where: { $0.surface === surface }) else { return }
        let gap: CGFloat = 60
        var frame = source.item.frame
        switch direction {
        case .right: frame.origin.x = frame.maxX + gap
        case .left: frame.origin.x = frame.minX - frame.width - gap
        case .down: frame.origin.y = frame.maxY + gap
        case .up: frame.origin.y = frame.minY - frame.height - gap
        }
        guard let node = addNode(.terminal, baseConfig: config, frame: frame) else { return }
        connect(source, to: node)
    }

    /// A terminal asked for a new tab: open a new terminal near it.
    func newTerminal(near surface: Ghostty.SurfaceView, config: Ghostty.SurfaceConfiguration?) {
        guard let source = terminalNodes.first(where: { $0.surface === surface }) else { return }
        let frame = source.item.frame.offsetBy(dx: 40, dy: 40)
        addNode(.terminal, baseConfig: config, frame: frame)
    }

    func close(surface: Ghostty.SurfaceView, confirm: Bool) {
        guard let node = terminalNodes.first(where: { $0.surface === surface }) else { return }
        closeNode(node, confirm: confirm)
    }

    func contains(_ surface: Ghostty.SurfaceView) -> Bool {
        terminalNodes.contains { $0.surface === surface }
    }

    // MARK: Refresh

    /// Diffs refresh on a timer while the canvas is on screen.
    func setRefreshing(_ refreshing: Bool) {
        diffTimer?.invalidate()
        diffTimer = nil
        guard refreshing else { return }
        refreshDiffs()
        diffTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshDiffs()
        }
    }

    private func refreshDiffs() {
        for case let diff as SuperNodeDiffView in nodeViews { diff.reload() }
    }

    private func updateEmptyState() {
        model.isEmpty = nodeViews.isEmpty
        emptyHint?.isHidden = !nodeViews.isEmpty
    }

    // MARK: Saving

    func documentDidChange() {
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func save() {
        saveWork?.cancel()
        saveWork = nil
        document.nodes = nodeViews.map(\.item)
        SuperNodeStore.save(document)
    }

    // MARK: Helpers

    private func prompt(title: String, message: String?, value: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// A menu item that runs a closure.
final class SuperNodeMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}

// MARK: - SwiftUI overlays

/// The floating bar at the bottom of the canvas for adding nodes and zooming.
struct SuperNodeDock: View {
    weak var canvas: SuperNodeCanvasView?
    @ObservedObject var model: SuperNodeCanvasModel

    var body: some View {
        HStack(spacing: 2) {
            button("terminal", "New terminal") { canvas?.addNode(.terminal) }
            Menu {
                ForEach(SuperNodeAgent.allCases, id: \.self) { agent in
                    Button(agent.name) { canvas?.addNode(.agent, agent: agent) }
                }
            } label: {
                Image(systemName: "sparkles")
                    .frame(width: 28, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New agent")
            button("note.text", "New note") { canvas?.addNode(.note) }
            button("plusminus", "New diff") { canvas?.addDiff(at: nil) }
            button("square.dashed", "New group") { canvas?.addNode(.group) }

            Divider().frame(height: 18).padding(.horizontal, 6)

            button("minus.magnifyingglass", "Zoom out") { canvas?.zoomOut() }
            Button {
                canvas?.setZoom(1)
            } label: {
                Text("\(Int((model.zoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(width: 42, height: 26)
            }
            .buttonStyle(.plain)
            .help("Reset zoom")
            button("plus.magnifyingglass", "Zoom in") { canvas?.zoomIn() }
            button("arrow.up.left.and.arrow.down.right", "Zoom to fit") { canvas?.zoomToFit() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A hosting view that never takes clicks, so they reach the canvas below.
private final class SuperNodePassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shown on an empty canvas.
private struct SuperNodeEmptyHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("SuperNode")
                .font(.title2.weight(.semibold))
            Text("Double-click for a terminal, right-click for more.\nDrag the link icon on a node to another node to connect them.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
