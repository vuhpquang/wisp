import AppKit
import GhosttyKit

/// How much CPU and memory SuperNode uses, in total and by node.
///
/// SuperNode's processes live in three places: terminals and agents in the
/// private tmux server (or, without tmux, under Wisp itself), each chat panel's
/// Claude Code process under Wisp, and each web node's WebKit process. The
/// tmux server outlives Wisp, so its sessions are counted even for projects
/// that aren't open, and even when SuperNode hasn't been opened since launch.
struct SuperNodeUsage: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
        /// The project the node is in, if known.
        let project: String?
        var cpu: Double = 0
        var memory: UInt64 = 0
        var pids: [pid_t] = []

        var processes: Int { pids.count }
    }

    var entries: [Entry] = []

    var cpu: Double { entries.reduce(0) { $0 + $1.cpu } }
    var memory: UInt64 { entries.reduce(0) { $0 + $1.memory } }
    var processes: Int { entries.reduce(0) { $0 + $1.processes } }
    var allPIDs: [pid_t] { entries.flatMap(\.pids) }
}

/// What SuperNode runs, read on the main thread from the open canvases, for
/// `SuperNodeUsage.measure` to turn into figures off the main thread.
struct SuperNodeUsageRoots {
    struct Root {
        let id: String
        let title: String
        let symbol: String
        let project: String?
        /// A node in tmux, found by session.
        var tmuxNode: UUID?
        /// A terminal outside tmux: its foreground process, counted from the
        /// shell Wisp started for it.
        var foregroundPID: pid_t?
        /// Processes counted with everything below them.
        var pids: [pid_t] = []
    }

    var roots: [Root] = []

    /// Titles of nodes in every saved project, for tmux sessions of projects
    /// that aren't open.
    var savedNodes: [UUID: (title: String, project: String, kind: SuperNodeItem.Kind)] = [:]

    /// Reads the open canvases. Call on the main thread.
    static func current(savedNodes: [UUID: (title: String, project: String, kind: SuperNodeItem.Kind)]) -> SuperNodeUsageRoots {
        var roots = SuperNodeUsageRoots(savedNodes: savedNodes)
        let controller = SuperNodeController.shared
        for canvas in controller.openCanvases {
            let project = controller.projects.first { $0.id == canvas.projectID }?.name
            for node in canvas.nodeViews {
                var root = Root(
                    id: node.item.id.uuidString,
                    title: node.displayTitle,
                    symbol: node.item.kind.symbol,
                    project: project)
                if let terminal = node as? SuperNodeTerminalView {
                    if terminal.usesTmux {
                        root.tmuxNode = node.item.id
                    } else if let surface = terminal.surface.surface {
                        let pid = ghostty_surface_foreground_pid(surface)
                        if pid > 0 { root.foregroundPID = pid_t(pid) }
                    }
                } else if let web = node as? SuperNodeWebView, let pid = web.contentProcessID {
                    root.pids = [pid]
                } else {
                    continue
                }
                roots.roots.append(root)
            }
            if let pid = canvas.chat.processID {
                roots.roots.append(Root(
                    id: "chat-" + canvas.projectID.uuidString,
                    title: "Chat",
                    symbol: "bubble.left.and.text.bubble.right",
                    project: project,
                    pids: [pid]))
            }
        }
        return roots
    }

    /// Node titles in every saved project. Reads files; call off the main thread.
    static func loadSavedNodes() -> [UUID: (title: String, project: String, kind: SuperNodeItem.Kind)] {
        var nodes: [UUID: (title: String, project: String, kind: SuperNodeItem.Kind)] = [:]
        for project in SuperNodeStore.savedIndex()?.projects ?? [] {
            for item in SuperNodeStore.load(project.id).nodes {
                let title = item.title ?? item.agent?.name ?? (item.directory as NSString?)?.lastPathComponent ?? item.kind.rawValue.capitalized
                nodes[item.id] = (title, project.name, item.kind)
            }
        }
        return nodes
    }
}

extension SuperNodeUsage {
    /// The pid of SuperNode's tmux server and each session's pane, by node.
    static func tmuxProcesses() -> (server: pid_t?, panes: [UUID: pid_t]) {
        guard SuperNodeTmux.executable != nil else { return (nil, [:]) }
        let result = SuperNodeTmux.run(["list-panes", "-a", "-F", "#{pid}\t#{session_name}\t#{pane_pid}"])
        guard result.status == 0 else { return (nil, [:]) }
        var server: pid_t?
        var panes: [UUID: pid_t] = [:]
        for line in result.output.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count == 3 else { continue }
            server = pid_t(fields[0]) ?? server
            guard fields[1].hasPrefix("wisp-"),
                  let id = UUID(uuidString: String(fields[1].dropFirst("wisp-".count))),
                  let pane = pid_t(fields[2]) else { continue }
            panes[id] = pane
        }
        return (server, panes)
    }

    /// Adds up every SuperNode process from a process sample. Runs tmux; call
    /// off the main thread.
    static func measure(_ roots: SuperNodeUsageRoots, samples: [ProcessSample]) -> SuperNodeUsage {
        let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let children = ProcessSampler.children(of: samples)
        let tmux = tmuxProcesses()
        let wisp = getpid()
        var counted: Set<pid_t> = []
        var usage = SuperNodeUsage()

        func entry(_ id: String, _ title: String, _ symbol: String, _ project: String?, roots: [pid_t]) -> SuperNodeUsage.Entry? {
            var entry = SuperNodeUsage.Entry(id: id, title: title, symbol: symbol, project: project)
            for root in roots {
                for pid in ProcessSampler.subtree(root, children: children) where counted.insert(pid).inserted {
                    guard let sample = byPID[pid] else { continue }
                    entry.pids.append(pid)
                    entry.cpu += sample.cpu ?? 0
                    entry.memory += sample.memory ?? 0
                }
            }
            return entry.pids.isEmpty ? nil : entry
        }

        var seenSessions: Set<UUID> = []
        for root in roots.roots {
            var pids = root.pids
            if let node = root.tmuxNode, let pane = tmux.panes[node] {
                pids.append(pane)
                seenSessions.insert(node)
            }
            if var pid = root.foregroundPID {
                // Climb to the process Wisp started for the terminal.
                while let parent = byPID[pid]?.ppid, parent != wisp, parent > 1 { pid = parent }
                if byPID[pid]?.ppid == wisp { pids.append(pid) }
            }
            if let entry = entry(root.id, root.title, root.symbol, root.project, roots: pids) {
                usage.entries.append(entry)
            }
        }

        // Sessions whose project isn't open keep running in the tmux server.
        for (node, pane) in tmux.panes where !seenSessions.contains(node) {
            let saved = roots.savedNodes[node]
            if let entry = entry(
                node.uuidString,
                saved?.title ?? "Session \(node.uuidString.prefix(8).lowercased())",
                saved?.kind.symbol ?? "terminal",
                saved.map { "\($0.project) (not open)" } ?? "Not in any project",
                roots: [pane]) {
                usage.entries.append(entry)
            }
        }

        // The server itself, last, so its panes are already counted.
        if let server = tmux.server, let entry = entry("tmux-server", "tmux server", "server.rack", nil, roots: [server]) {
            usage.entries.append(entry)
        }

        usage.entries.sort { $0.memory > $1.memory }
        return usage
    }
}
