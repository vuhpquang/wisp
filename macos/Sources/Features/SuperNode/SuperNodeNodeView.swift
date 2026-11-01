import AppKit
import Combine
import SwiftUI

/// A node on the SuperNode canvas: a header to drag it by, a body, and a grip
/// to resize it. Subclasses provide the body for each kind of node.
class SuperNodeNodeView: NSView {
    var item: SuperNodeItem {
        didSet {
            if item.frame != oldValue.frame { frame = item.frame }
            if item.color != oldValue.color || item.title != oldValue.title { refreshHeader() }
        }
    }

    weak var canvas: SuperNodeCanvasView?

    /// Higher values are drawn on top. Groups always stay behind other nodes.
    var zOrder: Int = 0

    var isSelected = false {
        didSet { updateBorder() }
    }

    let header = SuperNodeHeaderView()
    private let resizeGrip = SuperNodeResizeGrip()

    /// The content below the header, set by subclasses.
    var body: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let body { addSubview(body, positioned: .below, relativeTo: header) }
            needsLayout = true
        }
    }

    static let headerHeight: CGFloat = 30

    init(item: SuperNodeItem) {
        self.item = item
        super.init(frame: item.frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        header.node = self
        addSubview(header)
        resizeGrip.node = self
        addSubview(resizeGrip)
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        body?.frame = NSRect(
            x: 0,
            y: Self.headerHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.headerHeight))
        resizeGrip.frame = NSRect(x: bounds.width - 16, y: bounds.height - 16, width: 16, height: 16)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
        refreshHeader()
    }

    func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isSelected {
                layer?.borderWidth = 2
                layer?.borderColor = NSColor.controlAccentColor.cgColor
            } else {
                layer?.borderWidth = 1
                layer?.borderColor = (item.color.nsColor ?? .separatorColor).withAlphaComponent(0.7).cgColor
            }
        }
    }

    /// The title shown in the header.
    var displayTitle: String {
        item.title ?? defaultTitle
    }

    var defaultTitle: String {
        switch item.kind {
        case .terminal: "Terminal"
        case .agent: item.agent?.name ?? "Agent"
        case .note: "Note"
        case .diff: "Changes"
        case .group: "Group"
        case .editor: "Editor"
        }
    }

    /// Updates the header from the node's state. Subclasses add a subtitle,
    /// status badge and buttons.
    func refreshHeader() {
        header.icon.image = NSImage(systemSymbolName: item.kind.symbol, accessibilityDescription: nil)
        header.icon.contentTintColor = item.color.nsColor ?? .secondaryLabelColor
        header.titleLabel.stringValue = displayTitle
        header.updateTint(item.color.nsColor)
        updateBorder()
    }

    /// Whether the node runs something that would be lost when it closes.
    var needsConfirmClose: Bool { false }

    /// Shown when asking to close a node that needs confirmation.
    var closeWarning: String {
        "The process running in this node will be terminated."
    }

    /// Called before the node is removed from the canvas.
    func tearDown() {}
}

// MARK: - Header

/// The draggable header of a node.
final class SuperNodeHeaderView: NSView {
    weak var node: SuperNodeNodeView?

    let icon = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let badge = SuperNodeBadge()
    let subtitleLabel = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private let linkHandle = SuperNodeLinkHandle()
    private let closeButton: NSButton

    private var lastDragPoint: NSPoint?

    override init(frame frameRect: NSRect) {
        closeButton = SuperNodeHeaderView.button(symbol: "xmark", tooltip: "Close node", target: nil, action: nil)
        super.init(frame: frameRect)
        wantsLayer = true

        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingHead
        subtitleLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        badge.isHidden = true

        closeButton.target = self
        closeButton.action = #selector(closeNode)
        linkHandle.header = self
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.addArrangedSubview(linkHandle)
        buttons.addArrangedSubview(closeButton)

        let leading = NSStackView(views: [icon, titleLabel, badge, subtitleLabel])
        leading.orientation = .horizontal
        leading.spacing = 6
        leading.alignment = .centerY
        leading.setClippingResistancePriority(.defaultLow, for: .horizontal)

        for view in [leading, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    static func button(symbol: String, tooltip: String, target: AnyObject?, action: Selector?) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    /// Adds a button before the link handle and close button.
    func addButton(symbol: String, tooltip: String, target: AnyObject, action: Selector) {
        let button = Self.button(symbol: symbol, tooltip: tooltip, target: target, action: action)
        buttons.insertArrangedSubview(button, at: max(0, buttons.arrangedSubviews.count - 2))
    }

    func updateTint(_ color: NSColor?) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.windowBackgroundColor
            let tinted = color.map { base.blended(withFraction: 0.18, of: $0) ?? base } ?? base
            layer?.backgroundColor = tinted.withAlphaComponent(0.96).cgColor
        }
    }

    // Buttons and the link handle get their own clicks; the rest of the
    // header drags the node.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton || hit is SuperNodeLinkHandle { return hit }
        return self
    }

    @objc private func closeNode() {
        guard let node else { return }
        node.canvas?.closeNode(node)
    }

    override func mouseDown(with event: NSEvent) {
        guard let node, let canvas = node.canvas else { return }
        if event.clickCount == 2 {
            canvas.renameNode(node)
            return
        }
        lastDragPoint = canvas.worldPoint(for: event)
        canvas.beginMoving(node)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let node, let canvas = node.canvas, let last = lastDragPoint else { return }
        let point = canvas.worldPoint(for: event)
        canvas.move(node, by: CGSize(width: point.x - last.x, height: point.y - last.y))
        lastDragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        guard lastDragPoint != nil, let node else { return }
        lastDragPoint = nil
        node.canvas?.endMoving(node)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let node else { return nil }
        return node.canvas?.menu(for: node)
    }
}

/// A small pill showing an agent's status, such as RUNNING or NEEDS YOU.
final class SuperNodeBadge: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 9, weight: .bold)
        wantsLayer = true
        layer?.cornerRadius = 4
        alignment = .center
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 10, height: size.height + 2)
    }

    func show(_ text: String?, color: NSColor) {
        guard let text else {
            isHidden = true
            return
        }
        isHidden = false
        stringValue = text
        textColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
    }
}

/// Drag from this handle to another node to connect the two.
final class SuperNodeLinkHandle: NSView {
    weak var header: SuperNodeHeaderView?
    private let image = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Connect")
        image.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        toolTip = "Drag to another node to connect them"
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let node = header?.node else { return }
        node.canvas?.beginLink(from: node, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        header?.node?.canvas?.updateLink(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        header?.node?.canvas?.endLink(event: event)
    }
}

/// The corner grip that resizes a node.
final class SuperNodeResizeGrip: NSView {
    weak var node: SuperNodeNodeView?
    private var startPoint: NSPoint?
    private var startSize: CGSize = .zero

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        let path = NSBezierPath()
        for offset in [5.0, 9.0, 13.0] {
            path.move(to: NSPoint(x: bounds.maxX - 3, y: bounds.maxY - offset))
            path.line(to: NSPoint(x: bounds.maxX - offset, y: bounds.maxY - 3))
        }
        path.lineWidth = 1
        path.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let node, let canvas = node.canvas else { return }
        startPoint = canvas.worldPoint(for: event)
        startSize = node.item.frame.size
    }

    override func mouseDragged(with event: NSEvent) {
        guard let node, let canvas = node.canvas, let startPoint else { return }
        let point = canvas.worldPoint(for: event)
        canvas.resize(node, to: CGSize(
            width: startSize.width + point.x - startPoint.x,
            height: startSize.height + point.y - startPoint.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard startPoint != nil else { return }
        startPoint = nil
        node?.canvas?.documentDidChange()
    }
}

// MARK: - Terminal and agent nodes

/// A real Wisp terminal on the canvas. Agent nodes are terminals that started
/// a coding agent.
final class SuperNodeTerminalView: SuperNodeNodeView {
    let surface: Ghostty.SurfaceView
    private var cancellables: Set<AnyCancellable> = []
    private var headerRefreshPending = false

    init(item: SuperNodeItem, surface: Ghostty.SurfaceView, ghostty: Ghostty.App) {
        self.surface = surface
        super.init(item: item)

        let wrapper = Ghostty.SurfaceWrapper(surfaceView: surface, isSplit: false)
            .environmentObject(ghostty)
        body = NSHostingView(rootView: wrapper)
        layer?.backgroundColor = NSColor(ghostty.config.backgroundColor).cgColor

        header.addButton(
            symbol: "plusminus",
            tooltip: "Show the changes in this folder",
            target: self,
            action: #selector(showChanges))

        // Keep the header in step with the terminal's title, folder and status.
        surface.objectWillChange
            .sink { [weak self] _ in self?.scheduleHeaderRefresh() }
            .store(in: &cancellables)
        refreshHeader()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func scheduleHeaderRefresh() {
        guard !headerRefreshPending else { return }
        headerRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.headerRefreshPending = false
            self.refreshHeader()
        }
    }

    /// The terminal's current folder.
    var directory: String? {
        surface.pwd.flatMap { $0.isEmpty ? nil : $0 } ?? item.directory
    }

    override var defaultTitle: String {
        let title = surface.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty && title != "👻" { return title }
        return super.defaultTitle
    }

    override func refreshHeader() {
        super.refreshHeader()

        // Remember the folder so the terminal reopens there after a relaunch.
        if let pwd = surface.pwd, !pwd.isEmpty, pwd != item.directory {
            item.directory = pwd
            canvas?.documentDidChange()
        }

        var parts: [String] = []
        if let directory {
            parts.append((directory as NSString).abbreviatingWithTildeInPath)
            if let branch = TabGitInfo.branch(at: directory) { parts.append(branch) }
        }
        header.subtitleLabel.stringValue = parts.joined(separator: " · ")

        let status = AgentMonitorModel.agentStatus(of: surface)
            ?? (item.kind == .agent ? .idle : nil)
        switch status {
        case .needsInput: header.badge.show("NEEDS YOU", color: .systemOrange)
        case .error: header.badge.show("ERROR", color: .systemRed)
        case .working: header.badge.show("RUNNING", color: .controlAccentColor)
        case .idle: header.badge.show("IDLE", color: .secondaryLabelColor)
        case nil: header.badge.show(nil, color: .clear)
        }
        canvas?.needsDisplay = true
    }

    override var needsConfirmClose: Bool {
        surface.needsConfirmQuit
    }

    @objc private func showChanges() {
        canvas?.openDiff(for: self)
    }

    override func tearDown() {
        cancellables.removeAll()
    }
}

// MARK: - Note nodes

/// A sticky note. Connect it to a terminal or agent to send it as context.
final class SuperNodeNoteView: SuperNodeNodeView, NSTextViewDelegate {
    private let textView: NSTextView

    override init(item: SuperNodeItem) {
        let scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        super.init(item: item)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = item.text ?? ""
        textView.delegate = self
        body = scrollView

        header.addButton(
            symbol: "paperplane",
            tooltip: "Send this note to connected terminals",
            target: self,
            action: #selector(send))
        refreshHeader()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func refreshHeader() {
        super.refreshHeader()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = item.color.nsColor ?? .systemYellow
            let base = NSColor.textBackgroundColor
            layer?.backgroundColor = (base.blended(withFraction: 0.12, of: color) ?? base).cgColor
        }
    }

    override var item: SuperNodeItem {
        didSet {
            if item.text != textView.string { textView.string = item.text ?? "" }
        }
    }

    func textDidChange(_ notification: Notification) {
        item.text = textView.string
        canvas?.documentDidChange()
    }

    @objc private func send() {
        canvas?.sendNote(self)
    }
}

// MARK: - Group nodes

/// A labeled area that keeps related nodes together. Moving the group moves
/// the nodes inside it.
final class SuperNodeGroupView: SuperNodeNodeView {
    override init(item: SuperNodeItem) {
        super.init(item: item)
        zOrder = Int.min / 2
        refreshHeader()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func refreshHeader() {
        super.refreshHeader()
        let color = item.color.nsColor ?? .systemGray
        layer?.backgroundColor = color.withAlphaComponent(0.07).cgColor
        header.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        let count = canvas?.nodes(inside: self).count ?? 0
        header.subtitleLabel.stringValue = count == 1 ? "1 node" : "\(count) nodes"
    }

    // Only the header and resize grip take clicks; the inside of a group
    // behaves like the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === self ? nil : hit
    }
}
