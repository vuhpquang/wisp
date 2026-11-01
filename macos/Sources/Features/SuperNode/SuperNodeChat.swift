import AppKit
import Combine
import SwiftUI

/// One message in the SuperNode chat.
struct SuperNodeChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user, assistant
        /// Something Claude did, such as a canvas command.
        case action
        case error
    }

    var id = UUID()
    let role: Role
    var text: String
}

/// The chat beside the canvas. Each message runs Claude Code headless
/// (`claude -p`), signed in as the user's Claude Code, resuming the same
/// conversation. Claude changes the canvas with the `supernode` command,
/// which is the one shell command it's allowed to run.
final class SuperNodeChatModel: ObservableObject {
    @Published private(set) var messages: [SuperNodeChatMessage] = []
    @Published private(set) var isRunning = false
    @Published var draft = ""
    @Published var model: String = UserDefaults.standard.string(forKey: SuperNodeChatModel.modelKey) ?? "" {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }

    weak var canvas: SuperNodeCanvasView?
    /// Called when the conversation changes, to save it with the canvas.
    var onChange: (() -> Void)?

    private(set) var sessionID: String?
    private var process: Process?
    private var buffer = Data()

    static let modelKey = "SuperNodeChatModel"
    static let models: [(id: String, name: String)] = [("", "Default"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku")]

    /// The conversation saved with the canvas.
    struct Saved: Codable {
        var messages: [SuperNodeChatMessage]
        var sessionID: String?
    }

    var saved: Saved {
        Saved(messages: Array(messages.suffix(200)), sessionID: sessionID)
    }

    func restore(_ saved: Saved?) {
        guard let saved else { return }
        messages = saved.messages
        sessionID = saved.sessionID
    }

    // MARK: Sending

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        draft = ""
        append(.user, text)
        run(text)
    }

    func stop() {
        process?.terminate()
    }

    /// Starts a new conversation.
    func reset() {
        stop()
        messages = []
        sessionID = nil
        onChange?()
    }

    private func append(_ role: SuperNodeChatMessage.Role, _ text: String) {
        messages.append(SuperNodeChatMessage(role: role, text: text))
        onChange?()
    }

    private func run(_ text: String) {
        guard let canvas else { return }
        guard let claude = SuperNodeClaudeCLI.shared.path else {
            append(.error, "Couldn't find Claude Code. Install it, or make sure `claude` is on your shell's PATH.")
            return
        }
        SuperNodeCommands.install()

        var arguments = [
            "-p", text,
            "--output-format", "stream-json",
            "--verbose",
            "--append-system-prompt", instructions(for: canvas),
            // None of the user's MCP servers: they slow the start and distract.
            "--strict-mcp-config",
            // Nobody can answer a question in headless mode, so it would wait forever.
            "--disallowedTools", "AskUserQuestion", "ExitPlanMode", "EnterPlanMode", "ToolSearch", "Task", "Agent",
            // Claude may run the canvas command and read files, nothing else.
            "--allowedTools", "Bash(supernode:*)", "Bash(\"\(SuperNodeCommands.scriptURL.path)\":*)", "Read", "Grep", "Glob",
        ]
        if let sessionID { arguments += ["--resume", sessionID] }
        if !model.isEmpty { arguments += ["--model", model] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = SuperNodeClaudeCLI.shared.environment
        // `supernode` is on the PATH, so commands read plainly.
        let bin = SuperNodeCommands.scriptURL.deletingLastPathComponent().path
        environment["PATH"] = bin + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment[SuperNodeHooks.directoryVariable] = SuperNodeHooks.directory.path
        environment[SuperNodeCommands.canvasVariable] = canvas.projectID.uuidString
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        buffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] process in
            let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                output.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                if process.terminationReason == .uncaughtSignal {
                    self.append(.error, "Stopped.")
                } else if process.terminationStatus != 0 {
                    let message = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.append(.error, message.isEmpty ? "Claude Code exited with status \(process.terminationStatus)." : message)
                }
            }
        }

        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            append(.error, "Couldn't start Claude Code: \(error.localizedDescription)")
        }
    }

    // MARK: Reading Claude's output

    /// Handles each complete line of stream-json output.
    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(event)
        }
    }

    private func handle(_ event: [String: Any]) {
        if let session = event["session_id"] as? String { sessionID = session }
        switch event["type"] as? String {
        case "assistant":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { append(.assistant, text) }
                case "tool_use":
                    append(.action, Self.describeTool(block))
                default:
                    break
                }
            }
            canvas?.needsDisplay = true
        case "result":
            if event["is_error"] as? Bool == true, let result = event["result"] as? String {
                append(.error, result)
            }
            onChange?()
        default:
            break
        }
    }

    /// A short line for a tool Claude used, such as "create note".
    private static func describeTool(_ block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "tool"
        let input = block["input"] as? [String: Any] ?? [:]
        if name == "Bash", let command = input["command"] as? String,
           let range = command.range(of: SuperNodeCommands.scriptURL.lastPathComponent) {
            let rest = command[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            let verb = rest.split(separator: " ").first.map(String.init) ?? "help"
            var detail = ""
            if let start = rest.firstIndex(of: "{"), let end = rest.lastIndex(of: "}"),
               let object = (try? JSONSerialization.jsonObject(with: Data(rest[start...end].utf8))) as? [String: Any] {
                detail = ["kind", "title", "layout", "label", "text"].compactMap { object[$0] as? String }.first ?? ""
            }
            return "\(verb)\(detail.isEmpty ? "" : ": \(detail.prefix(60))")"
        }
        let detail = ["file_path", "pattern", "command"].compactMap { input[$0] as? String }.first
        return name + (detail.map { ": \($0.prefix(60))" } ?? "")
    }

    // MARK: Instructions

    private func instructions(for canvas: SuperNodeCanvasView) -> String {
        let listing = (try? JSONSerialization.data(withJSONObject: canvas.listing(), options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
        You are the assistant in the chat panel of Wisp SuperNode, a canvas where terminals, coding agents (Claude Code, Codex, Gemini), notes, git diffs, file editors, web pages and groups are nodes, connected by labeled lines that show how the work fits together. The user talks to you from beside the canvas and wants you to change it: create, edit, delete, connect and arrange nodes, type into terminals, and move the view.

        Change the canvas only with this command, run with the Bash tool:
        supernode <command> '<json>'
        (If `supernode` isn't found, use "\(SuperNodeCommands.scriptURL.path)".)

        \(SuperNodeCommands.usage)

        The canvas when this message was sent (canvas points; x grows right, y grows down):
        \(listing)

        Act with the command first, then reply in a sentence or two saying what changed. Don't ask the user questions; when something is unclear, make a sensible choice and say what you chose. Place new nodes so they don't overlap others. Reply in the user's language.
        """
    }
}

/// Finds the `claude` command the way the user's shell does, since apps
/// started from the Dock don't get the shell's PATH.
final class SuperNodeClaudeCLI {
    static let shared = SuperNodeClaudeCLI()

    private(set) var path: String?
    private(set) var environment: [String: String] = ProcessInfo.processInfo.environment

    private init() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `whence -p` and `type -P` skip shell functions that wrap claude.
        process.arguments = ["-lc", #"printf '%s\n%s' "$( (whence -p claude || type -P claude || command -v claude) 2>/dev/null | head -n 1)" "$PATH""#]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let found = lines.first, FileManager.default.isExecutableFile(atPath: found) { path = found }
            if lines.count > 1, !lines[1].isEmpty { environment["PATH"] = lines[1] }
        }
        if path == nil {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            path = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
    }
}

// MARK: - Panel

/// The chat panel at the right of the canvas.
struct SuperNodeChatPanel: View {
    @ObservedObject var chat: SuperNodeChatModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
                .frame(maxHeight: .infinity)
            Divider()
            composer
        }
        .frame(width: SuperNodeChatPanel.width)
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Divider() }
    }

    static let width: CGFloat = 380

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text("Canvas Assistant")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Menu {
                ForEach(SuperNodeChatModel.models, id: \.id) { model in
                    Button {
                        chat.model = model.id
                    } label: {
                        if chat.model == model.id { Label(model.name, systemImage: "checkmark") } else { Text(model.name) }
                    }
                }
            } label: {
                Text(SuperNodeChatModel.models.first { $0.id == chat.model }?.name ?? "Default")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Model")
            Button {
                chat.reset()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("New conversation")
            Button(action: onClose) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.plain)
            .help("Hide the chat (⌘J)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 38)
        .padding(.bottom, 10)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ask Claude to change the canvas.")
                                .font(.system(size: 12, weight: .medium))
                            ForEach(["Add a note with today's plan beside the API agent",
                                     "Open a terminal in ~/Work and connect it to the diff",
                                     "Tidy up the canvas along its connections",
                                     "Take me to the node that needs me"], id: \.self) { example in
                                Button {
                                    chat.draft = example
                                } label: {
                                    Text(example)
                                        .font(.system(size: 11))
                                        .multilineTextAlignment(.leading)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    ForEach(chat.messages) { message in
                        SuperNodeChatBubble(message: message)
                            .id(message.id)
                    }
                    if chat.isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .id("working")
                    }
                }
                .padding(12)
            }
            .onChange(of: chat.messages.count) { _ in
                withAnimation { proxy.scrollTo(chat.isRunning ? AnyHashable("working") : AnyHashable(chat.messages.last?.id), anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // An AppKit view has no width of its own here, so give it the row.
            SuperNodeChatField(text: $chat.draft, onSubmit: { chat.send() })
                .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
                .background(Color(NSColor.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
                .overlay(alignment: .topLeading) {
                    if chat.draft.isEmpty {
                        Text("Ask Claude to change the canvas…")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
            if chat.isRunning {
                Button {
                    chat.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Stop")
            } else {
                Button {
                    chat.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : .accentColor)
                .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (Return)")
            }
        }
        .padding(10)
    }
}

private struct SuperNodeChatBubble: View {
    let message: SuperNodeChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
            }
        case .assistant:
            Text(markdown)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .action:
            Label(message.text, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private var markdown: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: message.text, options: options)) ?? AttributedString(message.text)
    }
}

/// A multi-line message field: Return sends, ⇧Return adds a line.
private struct SuperNodeChatField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SuperNodeChatField

        init(_ parent: SuperNodeChatField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }
}
