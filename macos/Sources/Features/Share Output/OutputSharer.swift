import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// Shares selected terminal output as a Markdown code block or as an image of
/// a terminal window, for pasting into chats and tickets.
final class OutputSharer: NSObject {
    static let shared = OutputSharer()

    /// The menu items for a selection, added to the terminal's context menu.
    func menuItem(for text: String, title: String, surface: Ghostty.SurfaceView? = nil) -> NSMenuItem {
        let payload = Payload(text: text, title: title, surface: surface)
        let menu = NSMenu()
        for (label, action, symbol) in [
            ("Copy as Markdown", #selector(copyMarkdown(_:)), "text.badge.checkmark"),
            ("Copy as Image", #selector(copyImage(_:)), "photo.on.rectangle"),
            ("Save as Image…", #selector(saveImage(_:)), "square.and.arrow.down"),
        ] {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = payload
            item.setImageIfDesired(systemSymbolName: symbol)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        for agent in Agent.available {
            let item = NSMenuItem(title: agent.title, action: #selector(askAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = AgentRequest(agent: agent, payload: payload)
            item.setImageIfDesired(systemSymbolName: agent.symbol)
            menu.addItem(item)
        }

        let item = NSMenuItem(title: "Share Selection", action: nil, keyEquivalent: "")
        item.setImageIfDesired(systemSymbolName: "square.and.arrow.up")
        item.submenu = menu
        return item
    }

    private final class Payload {
        let text: String
        let title: String
        weak var surface: Ghostty.SurfaceView?
        init(text: String, title: String, surface: Ghostty.SurfaceView?) {
            self.text = text
            self.title = title
            self.surface = surface
        }
    }

    // MARK: Agents

    /// Somewhere to ask about the selection: a chat app, or a CLI agent run in
    /// a new split next to the terminal.
    private enum Agent: CaseIterable {
        case claudeDesktop, claudeCode, codex, gemini

        var title: String {
            switch self {
            case .claudeDesktop: "Ask Claude"
            case .claudeCode: "Ask Claude Code in a New Split"
            case .codex: "Ask Codex in a New Split"
            case .gemini: "Ask Gemini CLI in a New Split"
            }
        }

        var symbol: String {
            switch self {
            case .claudeDesktop: "bubble.left.and.text.bubble.right"
            case .claudeCode, .codex, .gemini: "terminal"
            }
        }

        /// The command that starts the CLI with `prompt` (a shell expression) as
        /// its first message, staying interactive.
        func command(prompt: String) -> String? {
            switch self {
            case .claudeDesktop: nil
            case .claudeCode: "claude \(prompt)"
            case .codex: "codex \(prompt)"
            case .gemini: "gemini -i \(prompt)"
            }
        }

        private var executable: String? {
            switch self {
            case .claudeDesktop: nil
            case .claudeCode: "claude"
            case .codex: "codex"
            case .gemini: "gemini"
            }
        }

        var isInstalled: Bool {
            if self == .claudeDesktop {
                return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.claudeBundleID) != nil
            }
            guard let executable else { return false }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local"]
                .contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(executable)") }
        }

        static let claudeBundleID = "com.anthropic.claudefordesktop"

        static var available: [Agent] { allCases.filter(\.isInstalled) }
    }

    private final class AgentRequest {
        let agent: Agent
        let payload: Payload
        init(agent: Agent, payload: Payload) {
            self.agent = agent
            self.payload = payload
        }
    }

    private static func prompt(for payload: Payload) -> String {
        "Here is output from my terminal (\(payload.title)). Help me understand it and what to do next.\n\n```\n\(trimmed(payload.text))\n```\n"
    }

    @objc private func askAgent(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? AgentRequest else { return }
        let prompt = Self.prompt(for: request.payload)

        guard request.agent != .claudeDesktop else {
            askClaudeDesktop(prompt)
            return
        }

        // Pass the prompt through a file so no part of the output is ever
        // interpreted by the shell.
        guard let surface = request.payload.surface,
              let controller = surface.window?.windowController as? BaseTerminalController else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Wisp")
        let file = dir.appendingPathComponent("prompt-\(UUID().uuidString).md")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try prompt.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            Ghostty.logger.warning("failed to write prompt: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let command = request.agent.command(prompt: "\"$(cat '\(file.path)')\"") else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = surface.pwd
        config.initialInput = command + "\n"
        _ = controller.newSplit(at: surface, direction: .right, baseConfig: config)
    }

    /// Open a new chat in the Claude app with the prompt filled in. The prompt
    /// is also copied in case the app doesn't fill it in.
    private func askClaudeDesktop(_ prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)

        var components = URLComponents()
        components.scheme = "claude"
        components.host = "claude.ai"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "q", value: prompt)]
        if let url = components.url, NSWorkspace.shared.open(url) { return }

        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Agent.claudeBundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    // MARK: Actions

    @objc private func copyMarkdown(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? Payload else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("```\n\(Self.trimmed(payload.text))\n```", forType: .string)
    }

    @objc private func copyImage(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? Payload,
              let png = Self.render(payload)?.png else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    @objc private func saveImage(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? Payload,
              let png = Self.render(payload)?.png else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "terminal-output.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url)
        }
    }

    // MARK: Rendering

    /// Lines without trailing spaces, and without leading or trailing blank lines.
    private static func trimmed(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Draw the text in a window-like card using the terminal's colors and font.
    private static func render(_ payload: Payload) -> NSBitmapImageRep? {
        let config = (NSApp.delegate as? AppDelegate)?.ghostty.config
        let background = config.map { NSColor($0.backgroundColor) } ?? .black
        let foreground = config?.wispForegroundColor ?? .white

        let fontSize: CGFloat = 14
        let font = WispSettings.shared.value("font-family").flatMap { NSFont(name: $0, size: fontSize) }
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let text = NSAttributedString(string: trimmed(payload.text), attributes: [
            .font: font,
            .foregroundColor: foreground,
        ])

        let textSize = text.boundingRect(
            with: NSSize(width: 1600, height: 4000),
            options: [.usesLineFragmentOrigin]).size

        let margin: CGFloat = 48 // around the card
        let padding: CGFloat = 22 // inside the card
        let titleBar: CGFloat = 36
        let cardSize = NSSize(
            width: max(ceil(textSize.width) + padding * 2, 360),
            height: ceil(textSize.height) + padding * 2 + titleBar)
        let size = NSSize(width: cardSize.width + margin * 2, height: cardSize.height + margin * 2)

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        // Backdrop: a soft gradient in Wisp's colors.
        NSGradient(colors: [
            NSColor(srgbRed: 0.20, green: 0.24, blue: 0.62, alpha: 1),
            NSColor(srgbRed: 0.33, green: 0.78, blue: 0.92, alpha: 1),
        ])?.draw(in: NSRect(origin: .zero, size: size), angle: -35)

        // Card with shadow.
        let cardRect = NSRect(x: margin, y: margin, width: cardSize.width, height: cardSize.height)
        let card = NSBezierPath(roundedRect: cardRect, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        background.withAlphaComponent(1).setFill()
        card.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Traffic lights and title.
        let dotY = cardRect.maxY - titleBar / 2
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            let dot = NSRect(x: cardRect.minX + 18 + CGFloat(index) * 20, y: dotY - 6, width: 12, height: 12)
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        let title = NSAttributedString(string: payload.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: foreground.withAlphaComponent(0.6),
        ])
        let titleSize = title.size()
        title.draw(at: NSPoint(x: cardRect.midX - titleSize.width / 2, y: dotY - titleSize.height / 2))

        text.draw(with: NSRect(
            x: cardRect.minX + padding,
            y: cardRect.minY + padding,
            width: ceil(textSize.width),
            height: ceil(textSize.height)),
            options: [.usesLineFragmentOrigin])

        return rep
    }
}

private extension NSBitmapImageRep {
    var png: Data? { representation(using: .png, properties: [:]) }
}

extension Ghostty.Config {
    /// The terminal's foreground color.
    var wispForegroundColor: NSColor {
        guard let config else { return .white }
        var color: ghostty_config_color_s = .init()
        let key = "foreground"
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else { return .white }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }
}
