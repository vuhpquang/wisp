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

/// The chat beside the canvas. It keeps one Claude Code process running
/// headless (`claude -p` with stream-json input and output), signed in as the
/// user's Claude Code, and sends each message to it, so only the first message
/// waits for Claude Code to start, and that is done when the panel opens.
/// Claude changes the canvas with the `supernode` command, the one shell
/// command it may run.
final class SuperNodeChatModel: ObservableObject {
    @Published private(set) var messages: [SuperNodeChatMessage] = []
    @Published private(set) var isRunning = false
    @Published var draft = ""
    @Published var model: String = UserDefaults.standard.string(forKey: SuperNodeChatModel.modelKey) ?? "sonnet" {
        didSet {
            UserDefaults.standard.set(model, forKey: Self.modelKey)
            // A running process keeps its model; start the next one with the new model.
            if model != oldValue { restart() }
        }
    }

    weak var canvas: SuperNodeCanvasView?
    /// Called when the conversation changes, to save it with the canvas.
    var onChange: (() -> Void)?

    private(set) var sessionID: String?
    private var process: Process?
    /// The running Claude Code process, for the Process Monitor.
    var processID: pid_t? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }
    private var input: FileHandle?
    private var buffer = Data()
    private var starting = false
    /// Messages sent while Claude Code was still starting.
    private var pending: [Data] = []
    /// Set when the process is ended on purpose, so it isn't reported as an error.
    private var stopping = false

    static let modelKey = "SuperNodeChatModel"
    /// Sonnet first: it answers quickly and handles canvas commands well.
    static let models: [(id: String, name: String)] = [("sonnet", "Sonnet"), ("haiku", "Haiku"), ("opus", "Opus"), ("", "Default")]

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

    /// Starts Claude Code ahead of the first message, as the panel opens.
    func prepare() {
        startIfNeeded()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, let canvas else { return }
        draft = ""
        append(.user, text)
        isRunning = true

        // The canvas as it is now goes with each message, so Claude rarely
        // needs to list it first.
        let listing = (try? JSONSerialization.data(withJSONObject: canvas.listing(), options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let content = "<canvas>\n\(listing)\n</canvas>\n\n\(text)"
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": content]]]]
        guard var line = try? JSONSerialization.data(withJSONObject: message) else { return }
        line.append(10)

        if let input, process?.isRunning == true {
            write(line, to: input)
        } else {
            pending.append(line)
            startIfNeeded()
        }
    }

    /// Stops the current reply. The conversation goes on with the next message.
    func stop() {
        guard let process else { return }
        stopping = true
        process.terminate()
    }

    /// Starts a new conversation.
    func reset() {
        stop()
        messages = []
        sessionID = nil
        onChange?()
    }

    private func restart() {
        guard let process, !isRunning else { return }
        stopping = true
        process.terminate()
    }

    private func append(_ role: SuperNodeChatMessage.Role, _ text: String) {
        messages.append(SuperNodeChatMessage(role: role, text: text))
        onChange?()
    }

    private func write(_ data: Data, to handle: FileHandle) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            isRunning = false
            append(.error, "Couldn't reach Claude Code: \(error.localizedDescription)")
        }
    }

    // MARK: The Claude Code process

    private func startIfNeeded() {
        guard process == nil, !starting, canvas != nil else { return }
        starting = true
        // Finding `claude` runs the login shell once; keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let cli = SuperNodeClaudeCLI.shared
            DispatchQueue.main.async { [weak self] in self?.launch(cli) }
        }
    }

    private func launch(_ cli: SuperNodeClaudeCLI) {
        starting = false
        guard process == nil, let canvas else { return }
        guard let claude = cli.path else {
            pending = []
            isRunning = false
            append(.error, "Couldn't find Claude Code. Install it, or make sure `claude` is on your shell's PATH.")
            return
        }
        SuperNodeCommands.install()

        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            // A short prompt of our own and only the tools the canvas needs keep
            // each request small, which saves the user's plan.
            "--system-prompt", Self.instructions,
            "--tools", "Bash,Read,Grep,Glob",
            "--disable-slash-commands",
            // The user's own hooks, plugins and MCP servers would run on every
            // tool call and slow each step down.
            "--setting-sources", "project,local",
            "--strict-mcp-config",
            // Claude may run the canvas command and read files, nothing else.
            "--allowedTools", "Bash(supernode:*)", "Bash(\"\(SuperNodeCommands.scriptURL.path)\":*)", "Read", "Grep", "Glob",
        ]
        if let sessionID { arguments += ["--resume", sessionID] }
        if !model.isEmpty { arguments += ["--model", model] }

        // An empty folder of its own, so no project's CLAUDE.md is read.
        let folder = SuperNodeHooks.directory.appendingPathComponent("chat")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        var environment = cli.environment
        // `supernode` is on the PATH, so commands read plainly.
        let bin = SuperNodeCommands.scriptURL.deletingLastPathComponent().path
        environment["PATH"] = bin + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment[SuperNodeHooks.directoryVariable] = SuperNodeHooks.directory.path
        environment[SuperNodeCommands.canvasVariable] = canvas.projectID.uuidString
        process.environment = environment

        let stdin = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = errors
        buffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        // Keep only the end of stderr, read as it comes so the pipe never fills.
        var errorTail = Data()
        let errorLock = NSLock()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            errorLock.lock()
            errorTail.append(data)
            if errorTail.count > 8000 { errorTail = errorTail.suffix(8000) }
            errorLock.unlock()
        }
        process.terminationHandler = { [weak self] process in
            errorLock.lock()
            let errorText = String(decoding: errorTail, as: UTF8.self)
            errorLock.unlock()
            DispatchQueue.main.async {
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                guard let self, self.process === process else { return }
                self.process = nil
                self.input = nil
                let wasRunning = self.isRunning
                self.isRunning = false
                if self.stopping {
                    if wasRunning { self.append(.error, "Stopped.") }
                } else if wasRunning || process.terminationStatus != 0 {
                    let message = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.append(.error, message.isEmpty ? "Claude Code exited with status \(process.terminationStatus)." : String(message.suffix(600)))
                }
                self.stopping = false
                self.pending = []
            }
        }

        do {
            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
            for line in pending { write(line, to: stdin.fileHandleForWriting) }
            pending = []
        } catch {
            pending = []
            isRunning = false
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
            // The turn is over; the process waits for the next message.
            isRunning = false
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
                if let steps = object["steps"] as? [[String: Any]] {
                    detail = steps.compactMap { $0["command"] as? String }.joined(separator: ", ")
                } else {
                    detail = ["kind", "title", "layout", "label", "text"].compactMap { object[$0] as? String }.first ?? ""
                }
            }
            return "\(verb)\(detail.isEmpty ? "" : ": \(detail.prefix(60))")"
        }
        let detail = ["file_path", "pattern", "command"].compactMap { input[$0] as? String }.first
        return name + (detail.map { ": \($0.prefix(60))" } ?? "")
    }

    // MARK: Instructions

    private static var instructions: String {
        """
        You are the assistant in the chat panel of Wisp SuperNode, a canvas where terminals, coding agents (Claude Code, Codex, Gemini), notes, git diffs, file editors, web pages and groups are nodes, connected by labeled lines that show how the work fits together. The user talks to you from beside the canvas and wants you to change it: create, edit, delete, connect and arrange nodes, type into terminals, and move the view.

        Change the canvas only with this command, run with the Bash tool:
        supernode <command> '<json>'
        (If `supernode` isn't found, use "\(SuperNodeCommands.scriptURL.path)".)

        \(SuperNodeCommands.usage)

        Each user message starts with the canvas as it is now, between <canvas> tags (canvas points; x grows right, y grows down), so you rarely need to list it.

        Do everything a message asks in as few commands as you can, ideally one batch, then reply in a sentence or two saying what changed. Don't ask the user questions; when something is unclear, make a sensible choice and say what you chose. Place new nodes so they don't overlap others. Reply in the user's language.
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
        // scrollableTextView() always holds an NSTextView.
        // swiftlint:disable:next force_cast
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
