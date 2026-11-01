import AppKit

/// Everything on the SuperNode canvas, saved between launches.
struct SuperNodeDocument: Codable {
    var nodes: [SuperNodeItem] = []
    var edges: [SuperNodeEdge] = []

    /// The world point shown at the top-left corner of the canvas.
    var origin: CGPoint = .zero
    var zoom: CGFloat = 1

    /// The board's columns. Optional so canvases saved before the board load.
    var boardColumns: [SuperNodeColumn]?

    var columns: [SuperNodeColumn] {
        get { boardColumns ?? SuperNodeColumn.defaults }
        set { boardColumns = newValue }
    }

    func item(_ id: UUID) -> SuperNodeItem? {
        nodes.first { $0.id == id }
    }
}

/// A column on the board.
struct SuperNodeColumn: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String

    static let defaults = ["To Do", "In Progress", "Review", "Done"].map { SuperNodeColumn(title: $0) }
}

enum SuperNodePriority: String, Codable, CaseIterable {
    case low, medium, high, urgent

    var name: String { rawValue.capitalized }

    var color: NSColor {
        switch self {
        case .low: .systemGray
        case .medium: .systemBlue
        case .high: .systemOrange
        case .urgent: .systemRed
        }
    }
}

struct SuperNodeComment: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var date = Date()
}

/// One node on the canvas.
struct SuperNodeItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case terminal, agent, note, diff, group, editor

        var symbol: String {
            switch self {
            case .terminal: "terminal"
            case .agent: "sparkles"
            case .note: "note.text"
            case .diff: "plusminus"
            case .group: "square.dashed"
            case .editor: "doc.text"
            }
        }

        var defaultSize: CGSize {
            switch self {
            case .terminal, .agent: CGSize(width: 640, height: 400)
            case .note: CGSize(width: 260, height: 200)
            case .diff: CGSize(width: 580, height: 460)
            case .group: CGSize(width: 900, height: 560)
            case .editor: CGSize(width: 620, height: 480)
            }
        }

        var minimumSize: CGSize {
            switch self {
            case .terminal, .agent: CGSize(width: 240, height: 140)
            case .note: CGSize(width: 160, height: 100)
            case .diff: CGSize(width: 280, height: 160)
            case .group: CGSize(width: 200, height: 120)
            case .editor: CGSize(width: 240, height: 140)
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var frame: CGRect

    /// A name the user gave the node. Terminals fall back to their title.
    var title: String?
    var color: SuperNodeColor = .none

    /// Working directory of a terminal or agent, or the repository a diff shows.
    var directory: String?

    /// The agent an agent node runs.
    var agent: SuperNodeAgent?

    /// The contents of a note.
    var text: String?

    /// The file an editor node shows.
    var file: String?

    /// The Claude Code session of an agent node, to resume after a relaunch.
    var sessionID: String?

    // Board card details.
    var column: UUID?
    var boardOrder: Double?
    var priority: SuperNodePriority?
    var due: Date?
    var details: String?
    var comments: [SuperNodeComment]?

    /// Nodes that show up as cards on the board.
    var isCard: Bool {
        kind == .terminal || kind == .agent || kind == .note
    }
}

/// A connection between two nodes, showing how they relate.
struct SuperNodeEdge: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: UUID
    var to: UUID
    var label: String?
}

enum SuperNodeColor: String, Codable, CaseIterable {
    case none, red, orange, yellow, green, blue, purple, pink

    var nsColor: NSColor? {
        switch self {
        case .none: nil
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        }
    }

    var name: String {
        self == .none ? "None" : rawValue.capitalized
    }
}

/// Coding agents that SuperNode can start in a node.
enum SuperNodeAgent: String, Codable, CaseIterable {
    case claude, codex, gemini

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }

    /// Typed into the shell to start the agent. Claude reports its status
    /// through SuperNode's hooks; on a relaunch the agent picks up its last
    /// conversation, by session when known.
    func command(resuming: Bool, sessionID: String?) -> String {
        switch self {
        case .claude:
            var command = "claude --settings \(SuperNodeHooks.shellQuote(SuperNodeHooks.settingsURL.path))"
            if resuming {
                command += sessionID.map { " --resume \(SuperNodeHooks.shellQuote($0))" } ?? " --continue"
            }
            return command
        case .codex:
            return resuming ? "codex resume --last" : "codex"
        case .gemini:
            return "gemini"
        }
    }
}

/// Reads and writes the canvas to Application Support.
enum SuperNodeStore {
    static var url: URL {
        // Debug builds keep their own canvas so they don't touch the installed app's.
        let isDebug = Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wisp")
            .appendingPathComponent(isDebug ? "supernode-debug.json" : "supernode.json")
    }

    static func load() -> SuperNodeDocument {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(SuperNodeDocument.self, from: data) else {
            return SuperNodeDocument()
        }
        return document
    }

    static func save(_ document: SuperNodeDocument) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(document) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
