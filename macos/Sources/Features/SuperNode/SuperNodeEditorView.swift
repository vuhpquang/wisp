import AppKit

/// A text file open for editing. ⌘S saves it. When an agent changes the file on
/// disk, the editor reloads it, or warns if there are unsaved edits.
final class SuperNodeEditorView: SuperNodeNodeView, NSTextViewDelegate {
    private let textView: SuperNodeEditorTextView
    private let scrollView = NSScrollView()

    private var savedText = ""
    private var diskDate: Date?
    private var isDirty = false
    private var changedOnDisk = false
    /// Why the file can't be edited, such as being binary.
    private var loadError: String?
    private var syntax: SuperNodeSyntax?
    private var highlightWork: DispatchWorkItem?

    /// Larger files aren't colored, so typing stays fast.
    private static let maxHighlightLength = 500_000

    /// Larger files open read-only so typing stays fast.
    private static let maxEditableSize = 2_000_000

    override init(item: SuperNodeItem) {
        // TextKit 1, which the line number ruler draws from.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        textView = SuperNodeEditorTextView(frame: .zero, textContainer: container)
        super.init(item: item)

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.delegate = self
        textView.onSave = { [weak self] in self?.save() }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.verticalRulerView = SuperNodeLineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        body = scrollView

        header.addButton(symbol: "arrow.up.forward.app", tooltip: "Open with the default app", target: self, action: #selector(openExternally))
        header.addButton(symbol: "arrow.clockwise", tooltip: "Reload from disk", target: self, action: #selector(reloadFromDisk))
        header.addButton(symbol: "square.and.arrow.down", tooltip: "Save (⌘S)", target: self, action: #selector(saveNow))

        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var path: String? { item.file }

    override var defaultTitle: String {
        path.map { ($0 as NSString).lastPathComponent } ?? "Editor"
    }

    override func refreshHeader() {
        super.refreshHeader()
        header.subtitleLabel.stringValue = path
            .map { (($0 as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath } ?? ""
        if loadError != nil {
            header.badge.show("READ ONLY", color: .secondaryLabelColor)
        } else if changedOnDisk {
            header.badge.show("CHANGED ON DISK", color: .systemRed)
        } else if isDirty {
            header.badge.show("EDITED", color: .systemOrange)
        } else {
            header.badge.show(nil, color: .clear)
        }
    }

    override var needsConfirmClose: Bool { isDirty }

    override var closeWarning: String {
        "Your unsaved changes to \(defaultTitle) will be lost."
    }

    // MARK: Loading and saving

    private func modificationDate() -> Date? {
        guard let path else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func load() {
        loadError = nil
        defer {
            isDirty = false
            changedOnDisk = false
            refreshHeader()
        }
        guard let path else { return }
        syntax = SuperNodeSyntax.forFile(path)
        guard let data = FileManager.default.contents(atPath: path) else {
            loadError = "Couldn't read the file"
            setText("Couldn't read \(path).", editable: false)
            return
        }
        if data.prefix(8000).contains(0) {
            loadError = "Binary file"
            setText("This is a binary file.", editable: false)
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        if data.count > Self.maxEditableSize { loadError = "Large file" }
        diskDate = modificationDate()
        savedText = text
        setText(text, editable: loadError == nil)
    }

    private func setText(_ text: String, editable: Bool) {
        let selection = textView.selectedRanges
        let visible = textView.visibleRect
        textView.string = text
        textView.isEditable = editable
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = editable ? .textColor : .secondaryLabelColor
        // Keep the place when the file reloads after an agent edited it.
        let length = (text as NSString).length
        textView.selectedRanges = selection.map {
            let range = $0.rangeValue
            return NSValue(range: NSRange(location: min(range.location, length), length: 0))
        }
        textView.scrollToVisible(visible)
        scrollView.verticalRulerView?.needsDisplay = true
        highlight()
    }

    // MARK: Syntax colors

    /// Colors the code. Temporary attributes only change how the text looks,
    /// so they never reach the undo stack or the saved file.
    private func highlight() {
        guard let layoutManager = textView.layoutManager else { return }
        let text = textView.string as NSString
        let all = NSRange(location: 0, length: text.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        guard let syntax, loadError == nil, text.length <= Self.maxHighlightLength else { return }
        for (range, token) in syntax.tokens(in: text, range: all) {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: token.color, forCharacterRange: range)
        }
    }

    private func scheduleHighlight() {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlight() }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc func saveNow() {
        save()
    }

    func save() {
        guard let path, loadError == nil else { return }
        let text = textView.string
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        savedText = text
        diskDate = modificationDate()
        isDirty = false
        changedOnDisk = false
        refreshHeader()
        canvas?.fileDidSave()
    }

    @objc private func reloadFromDisk() {
        load()
    }

    @objc private func openExternally() {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Reloads the file if it changed on disk and has no unsaved edits.
    func checkDisk() {
        guard path != nil, loadError == nil, let date = modificationDate(), date != diskDate else { return }
        if isDirty {
            if !changedOnDisk {
                changedOnDisk = true
                refreshHeader()
            }
        } else {
            load()
        }
    }

    /// Scrolls to a line, counted from 1, and highlights it.
    func go(toLine line: Int) {
        let text = textView.string as NSString
        var location = 0
        var current = 1
        while current < line, location < text.length {
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        let range = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        // Scroll after layout so the line lands in view on a new node.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.textView.scrollRangeToVisible(range)
            if range.length > 0 { self.textView.showFindIndicator(for: range) }
        }
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) {
        scheduleHighlight()
        let dirty = textView.string != savedText
        if dirty != isDirty {
            isDirty = dirty
            refreshHeader()
        }
    }
}

/// The editor's text view; ⌘S saves.
final class SuperNodeEditorTextView: NSTextView {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Line numbers beside the editor.
final class SuperNodeLineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// Where each line starts, rebuilt when the text changes.
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40

        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)), name: NSText.didChangeNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        rebuildLineStarts()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func textDidChange(_ notification: Notification) {
        rebuildLineStarts()
        needsDisplay = true
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override var needsDisplay: Bool {
        didSet {
            // Text set in code doesn't post didChange, so check the count here.
            if needsDisplay, let textView, (textView.string as NSString).length != lastLength { rebuildLineStarts() }
        }
    }

    private var lastLength = -1

    private func rebuildLineStarts() {
        guard let textView else { return }
        let text = textView.string as NSString
        lastLength = text.length
        var starts = [0]
        var index = 0
        while index < text.length {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index < text.length || (index == text.length && text.length > 0 && text.character(at: text.length - 1) == 10) {
                starts.append(index)
            }
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        let thickness = CGFloat(digits) * 7.5 + 14
        if abs(ruleThickness - thickness) > 0.5 { ruleThickness = thickness }
    }

    private func lineIndex(for location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.blended(withFraction: 0.04, of: .labelColor)?.setFill()
        bounds.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = lineIndex(for: characters.location)

        while line < lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(characters) { break }
            let lineRect: NSRect
            if start < text.length {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                lineRect = layoutManager.extraLineFragmentRect
            }
            let y = convert(NSPoint(x: 0, y: lineRect.minY + textView.textContainerInset.height), from: textView).y
            let label = NSAttributedString(string: "\(line + 1)", attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (lineRect.height - size.height) / 2))
            line += 1
        }
    }
}
