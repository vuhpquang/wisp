import AppKit

/// The `supernode` command, which lets Claude change the canvas: create,
/// edit and delete nodes, connect them, type into terminals, move the view
/// and tidy the layout. Like the hook script, it talks to Wisp through
/// files: a command file in `commands/`, answered in `results/`.
enum SuperNodeCommands {
    static var scriptURL: URL { SuperNodeHooks.directory.appendingPathComponent("bin/supernode") }
    static var commandsDirectory: URL { SuperNodeHooks.directory.appendingPathComponent("commands") }
    static var resultsDirectory: URL { SuperNodeHooks.directory.appendingPathComponent("results") }

    /// Names the project a command is for; without it, the current one.
    static let canvasVariable = "WISP_SUPERNODE_CANVAS"

    static func install() {
        let manager = FileManager.default
        try? manager.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.createDirectory(at: commandsDirectory, withIntermediateDirectories: true)
        try? manager.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        if (try? String(contentsOf: scriptURL, encoding: .utf8)) != script {
            try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private static let script = """
    #!/bin/sh
    # Wisp SuperNode canvas control. Written by Wisp; changes are overwritten.
    # Usage: supernode <command> ['<json arguments>']; run "supernode help".
    dir="$\(SuperNodeHooks.directoryVariable)"
    [ -n "$dir" ] || dir="$HOME/Library/Application Support/Wisp/supernode"
    command="${1:-help}"
    arguments="$2"
    [ -n "$arguments" ] || arguments='{}'
    umask 077
    mkdir -p "$dir/commands" "$dir/results"
    id="$(date +%s)-$$"
    tmp="$dir/commands/.$id.tmp"
    printf '%s\\n%s\\n%s' "$command" "$\(canvasVariable)" "$arguments" > "$tmp" && mv "$tmp" "$dir/commands/$id.cmd"
    i=0
    while [ "$i" -lt 300 ]; do
      if [ -f "$dir/results/$id" ]; then
        cat "$dir/results/$id"
        echo
        if head -c 9 "$dir/results/$id" | grep -q '"error"'; then rm -f "$dir/results/$id"; exit 1; fi
        rm -f "$dir/results/$id"
        exit 0
      fi
      if sleep 0.1 2>/dev/null; then i=$((i + 1)); else sleep 1; i=$((i + 10)); fi
    done
    rm -f "$dir/commands/$id.cmd"
    echo '{"error":"Wisp did not answer. Is SuperNode open?"}'
    exit 1

    """

    /// How to use the command, for Claude's instructions and `supernode help`.
    static let usage = """
    Commands (arguments are one JSON object in single quotes):
    - list: every node with its id, kind, title, place and size, plus connections and the view.
    - read '{"id":"…"}': a node's contents: a note's text, a terminal's recent output, an agent's recent conversation, a file's path, a page's URL, a diff's changed files.
    - create '{"kind":"note","title":"…","text":"…","near":"<id>"}': kinds are note, terminal, agent ("agent": "claude", "codex" or "gemini"), diff ("directory"), editor ("file"), web ("url") and group. Place it "near" a node (to its right), or at "x","y" in canvas points; "width", "height", "directory", "color" and "title" are optional. Prints the new node's id.
    - update '{"id":"…", …}': change "title", "text" (notes), "color" (none, red, orange, yellow, green, blue, purple, pink), "x", "y", "width", "height", or "url" (web pages).
    - delete '{"id":"…"}': close a node, ending what runs in it. The user can undo it with ⌘Z.
    - connect '{"from":"…","to":"…","label":"…"}' and disconnect '{"from":"…","to":"…"}'.
    - type '{"id":"…","text":"…","enter":true}': type into a terminal or agent; "enter" presses Return after.
    - focus '{"id":"…"}': move the view to a node. fit: show every node. view '{"x":…,"y":…,"zoom":…}': center the view on a point, zoom 0.15 to 1.5.
    - arrange '{"layout":"flow"}': tidy nodes, all or those in "ids". "flow" lays them out left to right along their connections; "grid" packs them in rows.
    - group '{"title":"…","ids":["…"]}': draw a group around nodes.
    - batch '{"steps":[{"command":"create","kind":"note","title":"Plan","as":"plan"},{"command":"connect","from":"$plan","to":"…"}]}': run several commands in one go, in order. A step with "as" names the node it creates or changes; later steps refer to it as "$name". Prefer one batch over several commands: it's much faster.
    Ids can be shortened to their first 8 characters. Each command prints JSON.
    """
}

// MARK: - Watching for commands

/// Watches for commands and runs them on the canvas they name.
final class SuperNodeCommandCenter {
    static let shared = SuperNodeCommandCenter()

    /// Finds the canvas for a project ID, or the current one when empty.
    var canvasFor: ((String) -> SuperNodeCanvasView?)?

    private var source: DispatchSourceFileSystemObject?

    func start() {
        guard source == nil else { return }
        SuperNodeCommands.install()
        let fd = open(SuperNodeCommands.commandsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.readCommands() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        readCommands()
    }

    private func readCommands() {
        let manager = FileManager.default
        let directory = SuperNodeCommands.commandsDirectory
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names.sorted() where name.hasSuffix(".cmd") && !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            try? manager.removeItem(at: url)
            let id = String(name.dropLast(".cmd".count))
            let parts = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let command = parts.first ?? "help"
            let project = parts.count > 1 ? parts[1] : ""
            let arguments = parts.count > 2 ? parts[2] : "{}"

            let result: Any
            if command == "help" {
                result = ["usage": SuperNodeCommands.usage]
            } else if let canvas = canvasFor?(project) {
                let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
                if let object {
                    result = canvas.run(command: command, arguments: object)
                } else {
                    result = ["error": "The arguments aren't a JSON object."]
                }
            } else {
                result = ["error": "SuperNode isn't open."]
            }
            write(result, id: id)
        }
    }

    private func write(_ result: Any, id: String) {
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{\"error\":\"Couldn't encode the result.\"}".utf8)
        let temporary = SuperNodeCommands.resultsDirectory.appendingPathComponent(".\(id).tmp")
        try? data.write(to: temporary)
        try? FileManager.default.moveItem(at: temporary, to: SuperNodeCommands.resultsDirectory.appendingPathComponent(id))
    }
}

// MARK: - Running commands

extension SuperNodeCanvasView {
    /// Runs one `supernode` command. Returns what it prints, as JSON.
    func run(command: String, arguments: [String: Any]) -> Any {
        switch command {
        case "list": return listing()
        case "read": return withNode(arguments) { read($0) }
        case "create": return create(arguments)
        case "update": return withNode(arguments) { update($0, arguments) }
        case "delete":
            return withNode(arguments) { node in
                closeNode(node, confirm: false)
                return ["deleted": node.item.id.uuidString]
            }
        case "connect", "disconnect":
            guard let from = findNode(arguments["from"]), let to = findNode(arguments["to"]) else {
                return ["error": "Give \"from\" and \"to\" as node ids."]
            }
            if command == "connect" {
                connect(from, to: to, label: arguments["label"] as? String)
                return ["connected": [from.item.id.uuidString, to.item.id.uuidString]]
            }
            for edge in document.edges where (edge.from == from.item.id && edge.to == to.item.id) || (edge.from == to.item.id && edge.to == from.item.id) {
                removeEdge(edge.id)
            }
            return ["disconnected": [from.item.id.uuidString, to.item.id.uuidString]]
        case "type": return withNode(arguments) { type(into: $0, arguments) }
        case "focus":
            return withNode(arguments) { node in
                showBoard(false)
                reveal(node, zoomIn: true)
                return ["focused": node.item.id.uuidString]
            }
        case "fit":
            showBoard(false)
            zoomToFit()
            return ["ok": true]
        case "view":
            if let zoom = number(arguments["zoom"]) { setZoom(zoom) }
            if let x = number(arguments["x"]), let y = number(arguments["y"]) { center(on: CGPoint(x: x, y: y)) }
            return ["view": viewDescription()]
        case "arrange": return arrange(arguments)
        case "group": return group(arguments)
        case "batch": return batch(arguments)
        default:
            return ["error": "Unknown command \"\(command)\". Run supernode help."]
        }
    }

    /// Runs several commands in order. A step's "as" names the node it made
    /// or changed, and later steps use "$name" in place of an id.
    private func batch(_ arguments: [String: Any]) -> Any {
        guard let steps = arguments["steps"] as? [[String: Any]] else {
            return ["error": "Give \"steps\": a list of {\"command\": …} objects."]
        }
        var names: [String: String] = [:]
        func resolve(_ value: Any) -> Any {
            if let text = value as? String, text.hasPrefix("$"), let id = names[String(text.dropFirst())] { return id }
            if let list = value as? [Any] { return list.map(resolve) }
            return value
        }
        var results: [Any] = []
        for step in steps {
            guard let command = step["command"] as? String, command != "batch" else {
                results.append(["error": "Each step needs a \"command\" other than batch."])
                continue
            }
            var stepArguments = step.filter { $0.key != "command" && $0.key != "as" }
            for (key, value) in stepArguments { stepArguments[key] = resolve(value) }
            let result = run(command: command, arguments: stepArguments)
            if let name = step["as"] as? String, let dictionary = result as? [String: Any] {
                // The node a step made or changed, whatever the command.
                let node = (dictionary["created"] ?? dictionary["updated"] ?? dictionary["focused"]) as? [String: Any]
                if let id = node?["id"] as? String ?? dictionary["focused"] as? String { names[name] = id }
            }
            results.append(result)
        }
        return ["steps": results]
    }

    // MARK: Finding nodes

    /// A node by its id or the first characters of it.
    private func findNode(_ value: Any?) -> SuperNodeNodeView? {
        guard let text = (value as? String)?.lowercased(), !text.isEmpty else { return nil }
        let matches = nodeViews.filter { $0.item.id.uuidString.lowercased().hasPrefix(text) }
        return matches.count == 1 ? matches[0] : nil
    }

    private func withNode(_ arguments: [String: Any], _ body: (SuperNodeNodeView) -> Any) -> Any {
        guard let node = findNode(arguments["id"]) else {
            return ["error": "No node with id \"\(arguments["id"] as? String ?? "")\"."]
        }
        return body(node)
    }

    private func number(_ value: Any?) -> CGFloat? {
        (value as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    // MARK: Describing

    func describe(_ node: SuperNodeNodeView) -> [String: Any] {
        let frame = node.item.frame
        var info: [String: Any] = [
            "id": node.item.id.uuidString,
            "kind": node.item.kind.rawValue,
            "title": node.displayTitle,
            "x": Int(frame.minX), "y": Int(frame.minY),
            "width": Int(frame.width), "height": Int(frame.height),
        ]
        if node.item.color != .none { info["color"] = node.item.color.rawValue }
        switch node {
        case let terminal as SuperNodeTerminalView:
            if let directory = terminal.directory { info["directory"] = directory }
            if let agent = terminal.item.agent { info["agent"] = agent.rawValue }
            if let status = terminal.status { info["status"] = status.text }
        case let note as SuperNodeNoteView:
            info["text"] = String((note.item.text ?? "").prefix(300))
        case let diff as SuperNodeDiffView:
            if let directory = diff.directory { info["directory"] = directory }
        case let editor as SuperNodeEditorView:
            if let path = editor.path { info["file"] = path }
        case let web as SuperNodeWebView:
            if let url = web.item.url { info["url"] = url }
        default:
            if node.item.kind == .group { info["contains"] = nodes(inside: node).map(\.item.id.uuidString) }
        }
        return info
    }

    private func viewDescription() -> [String: Any] {
        let visible = visibleWorldRect
        return [
            "centerX": Int(visible.midX), "centerY": Int(visible.midY),
            "width": Int(visible.width), "height": Int(visible.height),
            "zoom": (Double(zoom) * 100).rounded() / 100,
        ]
    }

    func listing() -> [String: Any] {
        [
            "nodes": nodeViews.map(describe),
            "connections": document.edges.map { edge -> [String: Any] in
                var info: [String: Any] = ["from": edge.from.uuidString, "to": edge.to.uuidString]
                if let label = edge.label { info["label"] = label }
                return info
            },
            "view": viewDescription(),
        ]
    }

    private func read(_ node: SuperNodeNodeView) -> Any {
        var info = describe(node)
        switch node {
        case let terminal as SuperNodeTerminalView:
            if terminal.item.kind == .agent {
                info["conversation"] = (try? String(contentsOf: SuperNodeContext.digestURL(terminal.item.id), encoding: .utf8))
                    ?? "No conversation yet."
            }
            let lines = terminal.recentOutput(lines: 80)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            info["output"] = lines.drop { $0.isEmpty }.suffix(80).joined(separator: "\n")
        case let note as SuperNodeNoteView:
            info["text"] = note.item.text ?? ""
        case let diff as SuperNodeDiffView:
            let status = diff.model.status
            info["staged"] = status.staged.map { "\($0.code) \($0.path)" }
            info["changes"] = status.unstaged.map { "\($0.code) \($0.path)" }
            if let branch = status.branch { info["branch"] = branch }
        default:
            break
        }
        return info
    }

    // MARK: Changing nodes

    private func create(_ arguments: [String: Any]) -> Any {
        guard let kindName = arguments["kind"] as? String, let kind = SuperNodeItem.Kind(rawValue: kindName) else {
            return ["error": "Give a \"kind\": note, terminal, agent, diff, editor, web or group."]
        }
        let size = CGSize(
            width: number(arguments["width"]) ?? kind.defaultSize.width,
            height: number(arguments["height"]) ?? kind.defaultSize.height)
        var origin: CGPoint
        if let near = findNode(arguments["near"]) {
            origin = CGPoint(x: near.item.frame.maxX + 80, y: near.item.frame.minY)
        } else if let x = number(arguments["x"]), let y = number(arguments["y"]) {
            origin = CGPoint(x: x, y: y)
        } else {
            let center = visibleCenter
            origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        }
        // Step down past nodes already there, so new nodes don't stack.
        var frame = CGRect(origin: origin, size: size)
        while nodeViews.contains(where: { $0.item.kind != .group && $0.item.frame.intersects(frame) }) {
            frame.origin.y += 40
            if frame.minY > origin.y + 4000 { break }
        }

        let directory = arguments["directory"] as? String
        let node: SuperNodeNodeView?
        switch kind {
        case .agent:
            let agent = (arguments["agent"] as? String).flatMap(SuperNodeAgent.init(rawValue:)) ?? .claude
            node = addNode(.agent, agent: agent, directory: directory, frame: frame)
        case .editor:
            guard let file = arguments["file"] as? String else { return ["error": "An editor needs a \"file\"."] }
            node = addEditor(path: (file as NSString).expandingTildeInPath, frame: frame)
        case .diff:
            node = addNode(.diff, directory: directory.map { ($0 as NSString).expandingTildeInPath }, frame: frame)
        default:
            node = addNode(kind, directory: directory.map { ($0 as NSString).expandingTildeInPath }, frame: frame)
        }
        guard let node else { return ["error": "Couldn't create the node."] }
        _ = update(node, arguments.filter { ["title", "text", "color", "url"].contains($0.key) })
        reveal(node)
        return ["created": describe(node)]
    }

    private func update(_ node: SuperNodeNodeView, _ arguments: [String: Any]) -> Any {
        checkpoint("Change Node")
        var item = node.item
        if let title = arguments["title"] as? String { item.title = title.isEmpty ? nil : title }
        if let text = arguments["text"] as? String, node.item.kind == .note { item.text = text }
        if let name = arguments["color"] as? String, let color = SuperNodeColor(rawValue: name) { item.color = color }
        if let x = number(arguments["x"]) { item.frame.origin.x = x }
        if let y = number(arguments["y"]) { item.frame.origin.y = y }
        let minimum = item.kind.minimumSize
        if let width = number(arguments["width"]) { item.frame.size.width = max(minimum.width, width) }
        if let height = number(arguments["height"]) { item.frame.size.height = max(minimum.height, height) }
        node.item = item
        if let url = arguments["url"] as? String, let web = node as? SuperNodeWebView { web.load(url) }
        if let terminal = node as? SuperNodeTerminalView { layoutSubagentCards(for: terminal) }
        needsDisplay = true
        documentDidChange()
        return ["updated": describe(node)]
    }

    private func type(into node: SuperNodeNodeView, _ arguments: [String: Any]) -> Any {
        guard let terminal = node as? SuperNodeTerminalView else { return ["error": "Only terminals and agents can be typed into."] }
        let text = arguments["text"] as? String ?? ""
        if !text.isEmpty { terminal.surface.surfaceModel?.sendText(text) }
        if arguments["enter"] as? Bool == true {
            // Return after the pasted text has arrived.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { terminal.surface.surfaceModel?.sendText("\r") }
        }
        return ["typed": terminal.item.id.uuidString]
    }

    // MARK: Layout

    private func arrange(_ arguments: [String: Any]) -> Any {
        let ids = (arguments["ids"] as? [String]).map { $0.compactMap { findNode($0)?.item.id } }
        let nodes = nodeViews.filter { $0.item.kind != .group && (ids.map { Set($0) }?.contains($0.item.id) ?? true) }
        guard !nodes.isEmpty else { return ["error": "No nodes to arrange."] }
        checkpoint("Arrange")

        let start = nodes.map(\.item.frame).reduce(nodes[0].item.frame) { $0.union($1) }.origin
        let gap: CGFloat = 80
        if (arguments["layout"] as? String) == "grid" {
            let columns = max(1, Int(Double(nodes.count).squareRoot().rounded(.up)))
            var x = start.x, y = start.y, rowHeight: CGFloat = 0
            for (index, node) in nodes.enumerated() {
                if index > 0 && index % columns == 0 {
                    x = start.x
                    y += rowHeight + gap
                    rowHeight = 0
                }
                node.item.frame.origin = CGPoint(x: x, y: y)
                x += node.item.frame.width + gap
                rowHeight = max(rowHeight, node.item.frame.height)
            }
        } else {
            // Columns by how far each node is from the start of its chain of connections.
            let members = Set(nodes.map(\.item.id))
            let edges = document.edges.filter { members.contains($0.from) && members.contains($0.to) && $0.from != $0.to }
            var depth: [UUID: Int] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.item.id, 0) })
            for _ in 0..<nodes.count {
                var changed = false
                for edge in edges where depth[edge.to, default: 0] < depth[edge.from, default: 0] + 1 {
                    depth[edge.to] = min(depth[edge.from, default: 0] + 1, nodes.count)
                    changed = true
                }
                if !changed { break }
            }
            var x = start.x
            for column in 0...(depth.values.max() ?? 0) {
                let inColumn = nodes.filter { depth[$0.item.id] == column }
                guard !inColumn.isEmpty else { continue }
                var y = start.y
                for node in inColumn {
                    node.item.frame.origin = CGPoint(x: x, y: y)
                    y += node.item.frame.height + gap
                }
                x += (inColumn.map(\.item.frame.width).max() ?? 0) + gap * 1.5
            }
        }
        for case let terminal as SuperNodeTerminalView in nodes { layoutSubagentCards(for: terminal) }
        needsDisplay = true
        documentDidChange()
        zoomToFit()
        return ["arranged": nodes.map(\.item.id.uuidString)]
    }

    private func group(_ arguments: [String: Any]) -> Any {
        let members = (arguments["ids"] as? [String] ?? []).compactMap { findNode($0) }
        guard let first = members.first else { return ["error": "Give the \"ids\" of the nodes to group."] }
        let rect = members.map(\.item.frame).reduce(first.item.frame) { $0.union($1) }
            .insetBy(dx: -30, dy: -30)
        let frame = CGRect(x: rect.minX, y: rect.minY - SuperNodeNodeView.headerHeight, width: rect.width, height: rect.height + SuperNodeNodeView.headerHeight)
        guard let group = addNode(.group, frame: frame) else { return ["error": "Couldn't create the group."] }
        if let title = arguments["title"] as? String { group.item.title = title }
        group.refreshHeader()
        documentDidChange()
        return ["created": describe(group)]
    }
}
