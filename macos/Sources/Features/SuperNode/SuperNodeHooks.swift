import AppKit

/// Claude Code reports to SuperNode through hooks instead of SuperNode
/// guessing from terminal titles. Agent nodes start Claude with
/// `--settings <file>` naming a hook script, so the user's own Claude settings
/// are never changed and Claude run anywhere else is unaffected.
///
/// The script and Wisp talk through files: each hook event is written to
/// `events/`, and a permission request waits for Wisp to write Allow or Deny
/// to `answers/`. Claude shows its own prompt at the same time; whichever is
/// answered first wins.
enum SuperNodeHooks {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wisp/supernode")
    }

    static var eventsDirectory: URL { directory.appendingPathComponent("events") }
    static var answersDirectory: URL { directory.appendingPathComponent("answers") }
    static var scriptURL: URL { directory.appendingPathComponent("claude-hook.sh") }
    static var settingsURL: URL { directory.appendingPathComponent("claude-settings.json") }

    /// Environment variables naming the node a terminal belongs to; the hook
    /// script does nothing without them.
    static let nodeVariable = "WISP_SUPERNODE_NODE"
    static let directoryVariable = "WISP_SUPERNODE_HOOK_DIR"

    /// How long a permission request waits for Allow or Deny from Wisp. The
    /// terminal prompt works throughout, except for a subagent's request,
    /// whose prompt only shows once the hook returns.
    static let permissionWait = 40

    /// Plans and questions take minutes to read, so they wait longer. Claude
    /// shows its own prompt at the same time, so the wait blocks nothing.
    static let interactiveWait = 540

    /// Hook events and how long Claude should wait for each.
    private static let events: [(name: String, matcher: Bool, timeout: Int)] = [
        ("SessionStart", false, 10),
        ("UserPromptSubmit", false, 10),
        ("PreToolUse", true, 10),
        ("PostToolUse", true, 10),
        // Longer than the wait for plans and questions.
        ("PermissionRequest", true, interactiveWait + 60),
        ("Notification", false, 10),
        ("Stop", false, 10),
        ("SubagentStop", false, 10),
        ("SessionEnd", false, 10),
    ]

    /// Writes the hook script and Claude settings file if they're missing or out of date.
    static func install() {
        let manager = FileManager.default
        try? manager.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        try? manager.createDirectory(at: answersDirectory, withIntermediateDirectories: true)

        if (try? String(contentsOf: scriptURL, encoding: .utf8)) != script {
            try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var hooks: [String: Any] = [:]
        for event in events {
            var entry: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": "\(shellQuote(scriptURL.path)) \(event.name)",
                    "timeout": event.timeout,
                ]],
            ]
            if event.matcher { entry["matcher"] = "*" }
            hooks[event.name] = [entry]
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           (try? Data(contentsOf: settingsURL)) != data {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The decision a permission hook prints, as one line of JSON.
    static func decision(_ decision: [String: Any]) -> String? {
        let object = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes Allow, Deny, Pass (let the terminal prompt answer) or a decision
    /// from `decision(_:)` for a held permission request.
    static func answer(_ id: String, with answer: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: answersDirectory, withIntermediateDirectories: true)
        let temporary = answersDirectory.appendingPathComponent(".\(id).tmp")
        let destination = answersDirectory.appendingPathComponent(id)
        guard (try? answer.write(to: temporary, atomically: false, encoding: .utf8)) != nil else { return }
        _ = try? manager.replaceItemAt(destination, withItemAt: temporary)
        if !manager.fileExists(atPath: destination.path) {
            try? manager.moveItem(at: temporary, to: destination)
        }
    }

    /// POSIX sh, no dependencies. Inert unless started from a SuperNode node.
    private static let script = """
    #!/bin/sh
    # Wisp SuperNode hook for Claude Code. Written by Wisp; changes are overwritten.
    # Reports agent status to Wisp and lets Wisp answer permission requests.
    dir="$\(directoryVariable)"
    node="$\(nodeVariable)"
    [ -n "$dir" ] && [ -n "$node" ] || exit 0
    event="$1"
    umask 077
    mkdir -p "$dir/events" "$dir/answers" 2>/dev/null
    id="${node}__${event}__$(date +%s)-$$"
    tmp="$dir/events/.$id.tmp"
    cat > "$tmp" || exit 0

    # Plans and questions in the main conversation wait longer; a subagent's
    # prompt waits for this hook, so its requests stay short.
    limit=$((\(permissionWait) * 2))
    if [ "$event" = "PermissionRequest" ] && ! grep -q '"agent_id"' "$tmp"; then
      case "$(grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[A-Za-z]*"' "$tmp" | head -n 1)" in
        *'"ExitPlanMode"'|*'"AskUserQuestion"') limit=$((\(interactiveWait) * 2)) ;;
      esac
    fi
    mv "$tmp" "$dir/events/$id.json"

    [ "$event" = "PermissionRequest" ] || exit 0
    answer="$dir/answers/$id"
    i=0
    while [ "$i" -lt "$limit" ]; do
      if [ -f "$answer" ]; then
        reply=$(cat "$answer")
        rm -f "$answer"
        case "$reply" in
          allow) printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ;;
          deny) printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied in Wisp SuperNode."}}}' ;;
          '{"hookSpecificOutput":'*) printf '%s' "$reply" ;;
        esac
        exit 0
      fi
      if sleep 0.5 2>/dev/null; then i=$((i + 1)); else sleep 1; i=$((i + 2)); fi
    done
    exit 0

    """
}

// MARK: - Events

/// One hook event from Claude Code in an agent node.
struct SuperNodeHookEvent {
    /// The file name without extension, which the answer file is named after.
    let id: String
    let node: UUID
    let name: String
    let payload: [String: Any]

    var sessionID: String? { payload["session_id"] as? String }
    var toolName: String? { payload["tool_name"] as? String }
    var toolInput: [String: Any]? { payload["tool_input"] as? [String: Any] }
    var toolUseID: String? { payload["tool_use_id"] as? String }
    var message: String? { payload["message"] as? String }
    /// Set when a subagent, not the main conversation, sent the event.
    var isSubagent: Bool { payload["agent_id"] != nil }

    /// A short description of what a tool is about to do.
    var toolSummary: String? {
        guard let input = toolInput else { return nil }
        for key in ["command", "file_path", "url", "pattern", "description", "prompt", "query", "path"] {
            if let value = input[key] as? String, !value.isEmpty {
                let line = value.split(separator: "\n").first.map(String.init) ?? value
                return line.count > 160 ? String(line.prefix(160)) + "…" : line
            }
        }
        return nil
    }
}

/// What an agent node is doing, from its hook events.
struct SuperNodeAgentState: Equatable {
    enum Phase: Equatable {
        case idle, working, needsYou, done
    }

    /// A permission request waiting for an answer.
    struct Permission: Equatable {
        enum Kind: Equatable {
            /// A tool to allow or deny.
            case tool
            /// A plan to approve or send back, in Markdown.
            case plan(String)
            case questions([Question])
        }

        let id: String
        let tool: String
        let summary: String?
        let kind: Kind
        /// The tool's input as JSON, which a question's answer is added to.
        let input: Data?
    }

    /// One question from AskUserQuestion.
    struct Question: Equatable, Identifiable {
        struct Option: Equatable, Identifiable {
            let label: String
            let description: String?
            var id: String { label }
        }

        let text: String
        let header: String?
        let multiSelect: Bool
        let options: [Option]
        var id: String { text }
    }

    var phase: Phase = .idle
    var tool: String?
    var permission: Permission?
    var message: String?
    /// Subagents running now, by tool use ID, with what they're doing.
    var subagents: [String: String] = [:]
    var sessionID: String?

    /// Updates the state for an event. Returns what the user should be told,
    /// if anything.
    mutating func apply(_ event: SuperNodeHookEvent) -> Phase? {
        if let session = event.sessionID { sessionID = session }
        let before = phase

        switch event.name {
        case "SessionStart":
            phase = .idle
            permission = nil
            subagents = [:]
        case "UserPromptSubmit":
            phase = .working
            permission = nil
            message = nil
        case "PreToolUse":
            tool = event.toolName
            if event.toolName == "Task" || event.toolName == "Agent", let id = event.toolUseID {
                subagents[id] = event.toolSummary ?? "Subagent"
            }
            if permission == nil { phase = .working }
        case "PostToolUse":
            if let id = event.toolUseID { subagents[id] = nil }
            // A tool that ran was answered, here or in the terminal.
            if permission?.tool == event.toolName { permission = nil }
            if permission == nil { phase = .working }
        case "PermissionRequest":
            let tool = event.toolName ?? "a tool"
            permission = Permission(
                id: event.id,
                tool: tool,
                summary: event.toolSummary,
                kind: Self.kind(of: tool, input: event.toolInput),
                input: event.toolInput.flatMap { try? JSONSerialization.data(withJSONObject: $0) })
            phase = .needsYou
        case "Notification":
            message = event.message
            // "Claude is waiting for your input" arrives after a turn ends; the
            // permission notification duplicates PermissionRequest.
            if let message = event.message?.lowercased(), message.contains("permission") || message.contains("waiting") {
                phase = .needsYou
            }
        case "Stop":
            if !event.isSubagent {
                phase = .done
                permission = nil
                tool = nil
                subagents = [:]
            }
        case "SubagentStop":
            break
        case "SessionEnd":
            phase = .idle
            permission = nil
            tool = nil
            subagents = [:]
        default:
            break
        }

        guard phase != before else { return nil }
        return phase == .needsYou || phase == .done ? phase : nil
    }

    private static func kind(of tool: String, input: [String: Any]?) -> Permission.Kind {
        switch tool {
        case "ExitPlanMode":
            return .plan(input?["plan"] as? String ?? "")
        case "AskUserQuestion":
            let questions = (input?["questions"] as? [[String: Any]] ?? []).compactMap { question -> Question? in
                guard let text = question["question"] as? String else { return nil }
                let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> Question.Option? in
                    guard let label = option["label"] as? String else { return nil }
                    return Question.Option(label: label, description: option["description"] as? String)
                }
                return Question(
                    text: text,
                    header: question["header"] as? String,
                    multiSelect: question["multiSelect"] as? Bool ?? false,
                    options: options)
            }
            return questions.isEmpty ? .tool : .questions(questions)
        default:
            return .tool
        }
    }
}

// MARK: - Answers

/// How the user answered a permission request, turned into the decision the
/// hook prints. Claude ignores a bare allow for plans and questions; they need
/// `updatedInput`.
enum SuperNodePermissionAnswer {
    case allow
    case deny
    /// Let the terminal prompt answer.
    case pass
    /// Approve the plan. `mode` switches the permission mode, or nil to go back
    /// to the mode before planning.
    case approvePlan(mode: String?)
    /// Send the plan back with feedback.
    case revisePlan(String)
    /// Answers by question text: chosen labels, or typed text.
    case answers([String: String])

    func reply(for permission: SuperNodeAgentState.Permission) -> String? {
        switch self {
        case .allow: return "allow"
        case .deny: return "deny"
        case .pass: return "pass"
        case let .approvePlan(mode):
            var decision: [String: Any] = ["behavior": "allow", "updatedInput": [String: Any]()]
            if let mode {
                decision["updatedPermissions"] = [["type": "setMode", "mode": mode, "destination": "session"]]
            }
            return SuperNodeHooks.decision(decision)
        case let .revisePlan(feedback):
            let message = feedback.isEmpty ? "The user wants to keep planning." : feedback
            return SuperNodeHooks.decision(["behavior": "deny", "message": message])
        case let .answers(answers):
            var input = permission.input.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            input["answers"] = answers
            return SuperNodeHooks.decision(["behavior": "allow", "updatedInput": input])
        }
    }
}

// MARK: - Watching for events

/// Watches the events folder and hands each event to the canvas.
final class SuperNodeHookCenter {
    static let shared = SuperNodeHookCenter()

    /// Called on the main thread for every event.
    var onEvent: ((SuperNodeHookEvent) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        SuperNodeHooks.install()
        removeStaleFiles()

        let fd = open(SuperNodeHooks.eventsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.readEvents() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        readEvents()
    }

    private func readEvents() {
        let manager = FileManager.default
        let directory = SuperNodeHooks.eventsDirectory
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }

        // Oldest first, so events apply in order. Names end in "<seconds>-<pid>".
        let files = names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted { lhs, rhs in
                let l = (try? manager.attributesOfItem(atPath: directory.appendingPathComponent(lhs).path))?[.creationDate] as? Date
                let r = (try? manager.attributesOfItem(atPath: directory.appendingPathComponent(rhs).path))?[.creationDate] as? Date
                return (l ?? .distantPast, lhs) < (r ?? .distantPast, rhs)
            }

        for name in files {
            let url = directory.appendingPathComponent(name)
            defer { try? manager.removeItem(at: url) }
            let id = String(name.dropLast(".json".count))
            let parts = id.components(separatedBy: "__")
            guard parts.count == 3,
                  let node = UUID(uuidString: parts[0]),
                  let data = try? Data(contentsOf: url),
                  let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            onEvent?(SuperNodeHookEvent(id: id, node: node, name: parts[1], payload: payload))
        }
    }

    /// Events and answers left behind by sessions that were killed.
    private func removeStaleFiles() {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-600)
        for directory in [SuperNodeHooks.eventsDirectory, SuperNodeHooks.answersDirectory] {
            for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] {
                let path = directory.appendingPathComponent(name).path
                let date = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                if (date ?? .distantPast) < cutoff { try? manager.removeItem(atPath: path) }
            }
        }
    }
}
