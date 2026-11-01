import Foundation

/// Runs each SuperNode terminal inside its own tmux session, so it keeps
/// running when Wisp quits and comes back when Wisp opens again. A private
/// socket and config keep these sessions apart from the user's own tmux.
///
/// tmux doesn't survive a restart of the Mac, so the scrollback of every
/// session is saved now and then; a node whose session is gone starts a new
/// one that prints the saved scrollback first, and agents resume their
/// conversation.
enum SuperNodeTmux {
    // MARK: Setup

    static let keepRunningKey = "SuperNodeKeepTerminalsRunning"

    /// The tmux binary, if one is installed.
    static let executable: String? = {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Whether new terminals run in tmux: on by default when tmux is installed.
    static var isEnabled: Bool {
        guard executable != nil else { return false }
        return UserDefaults.standard.object(forKey: keepRunningKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: keepRunningKey)
    }

    /// Debug builds use their own server so they never touch the installed app's sessions.
    static var socket: String {
        Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true ? "wisp-supernode-debug" : "wisp-supernode"
    }

    static var configURL: URL { SuperNodeHooks.directory.appendingPathComponent("tmux.conf") }
    /// Per socket, so a debug build never cleans up the installed app's files.
    static var scrollbackDirectory: URL {
        SuperNodeHooks.directory.appendingPathComponent("scrollback").appendingPathComponent(socket)
    }

    static func sessionName(_ id: UUID) -> String {
        "wisp-" + id.uuidString.lowercased()
    }

    /// `=` makes tmux match the session name exactly instead of by prefix.
    private static func target(_ id: UUID) -> String {
        "=" + sessionName(id) + ":"
    }

    /// Shells, so closing a node that only shows a prompt needn't ask first.
    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu", "-zsh", "-bash", "login"]

    static func isShell(_ command: String) -> Bool {
        shells.contains(command)
    }

    /// Writes the config, and reloads it into a running server if it changed.
    static func writeConfig() {
        try? FileManager.default.createDirectory(at: scrollbackDirectory, withIntermediateDirectories: true)
        guard (try? String(contentsOf: configURL, encoding: .utf8)) != config else { return }
        try? config.write(to: configURL, atomically: true, encoding: .utf8)
        _ = run(["source-file", configURL.path])
    }

    /// The node terminal should look like a plain terminal, so tmux stays out
    /// of sight: no status bar, no prefix key, and its title passed through.
    private static let config = """
    # Written by Wisp for SuperNode terminals; changes are overwritten.
    set -g status off
    set -g prefix None
    unbind C-b
    set -g mouse on
    set -g history-limit 50000
    set -g default-terminal "xterm-256color"
    set -sg escape-time 10
    set -g focus-events on
    set -g destroy-unattached off
    setw -g aggressive-resize on
    # A long-lived server keeps every feature ever added, so start from the defaults.
    set -su terminal-features
    set -as terminal-features ",*:RGB"
    set -as terminal-features ",*:clipboard"
    set -as terminal-features ",*:hyperlinks"
    set -as terminal-features ",*:extkeys"
    set -s extended-keys on
    set -g set-clipboard on
    set -g allow-passthrough on
    # The terminal's title is the program's title, or the folder for a bare shell.
    set -g set-titles on
    set -g set-titles-string "#{?#{==:#{pane_title},#{host}},#{b:pane_current_path},#{pane_title}}"
    set -g bell-action any
    set -g visual-bell off
    # Selecting with the mouse copies to the clipboard, as without tmux.
    bind -T copy-mode MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel
    bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel
    bind -T copy-mode DoubleClick1Pane send-keys -X select-word \\; send-keys -X copy-pipe-and-cancel
    bind -T copy-mode-vi DoubleClick1Pane send-keys -X select-word \\; send-keys -X copy-pipe-and-cancel

    """

    // MARK: Commands

    @discardableResult
    static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        guard let executable else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-L", socket, "-f", configURL.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func hasSession(_ id: UUID) -> Bool {
        run(["has-session", "-t", "=" + sessionName(id)]).status == 0
    }

    /// The shell command a node's surface runs: attach to the node's session,
    /// creating it if needed. `replay` is saved scrollback to print in a new session.
    static func attachCommand(for id: UUID, directory: String?, environment: [String: String], replay: URL?) -> String {
        guard let executable else { return "" }
        var parts = [executable, "-L", socket, "-f", configURL.path, "new-session", "-A", "-s", sessionName(id)]
        if let directory { parts += ["-c", directory] }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) { parts += ["-e", "\(key)=\(value)"] }
        if let replay {
            let file = SuperNodeHooks.shellQuote(replay.path)
            parts.append("cat \(file); rm -f \(file); exec \"$SHELL\" -l")
        }
        return parts.map(SuperNodeHooks.shellQuote).joined(separator: " ")
    }

    static func kill(_ id: UUID) {
        DispatchQueue.global(qos: .utility).async {
            run(["kill-session", "-t", "=" + sessionName(id)])
            try? FileManager.default.removeItem(at: scrollbackURL(id))
        }
    }

    /// What each session's pane is doing, by node.
    struct Pane {
        let path: String
        let command: String
    }

    /// Reads every SuperNode session at once. Call this off the main thread.
    static func panes() -> [UUID: Pane] {
        let format = "#{session_name}\t#{pane_current_path}\t#{pane_current_command}"
        let result = run(["list-panes", "-a", "-F", format])
        guard result.status == 0 else { return [:] }
        var panes: [UUID: Pane] = [:]
        for line in result.output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[0].hasPrefix("wisp-"),
                  let id = UUID(uuidString: String(fields[0].dropFirst("wisp-".count))) else { continue }
            panes[id] = Pane(path: fields[1], command: fields[2])
        }
        return panes
    }

    /// The last lines of a session's history as plain text.
    static func capture(_ id: UUID, lines: Int) -> String? {
        let result = run(["capture-pane", "-p", "-J", "-S", "-\(lines)", "-t", target(id)])
        return result.status == 0 ? result.output : nil
    }

    // MARK: Scrollback for restarts

    static func scrollbackURL(_ id: UUID) -> URL {
        scrollbackDirectory.appendingPathComponent(id.uuidString + ".txt")
    }

    /// Saves the history of each session, with colors, for after a restart.
    static func saveScrollback(of ids: [UUID]) {
        try? FileManager.default.createDirectory(at: scrollbackDirectory, withIntermediateDirectories: true)
        for id in ids {
            let result = run(["capture-pane", "-p", "-e", "-J", "-S", "-3000", "-t", target(id)])
            guard result.status == 0 else { continue }
            var text = result.output
            // Drop the blank rows below the prompt.
            while text.hasSuffix("\n\n") { text.removeLast() }
            try? text.write(to: scrollbackURL(id), atomically: true, encoding: .utf8)
        }
    }

    /// Ends sessions and removes saved scrollback of nodes that no longer
    /// exist, such as ones closed while their session couldn't be reached.
    static func removeOrphans(keeping ids: Set<UUID>) {
        DispatchQueue.global(qos: .utility).async {
            for id in panes().keys where !ids.contains(id) {
                run(["kill-session", "-t", "=" + sessionName(id)])
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: scrollbackDirectory.path)) ?? []
            for name in names {
                guard let id = UUID(uuidString: (name as NSString).deletingPathExtension), !ids.contains(id) else { continue }
                try? FileManager.default.removeItem(at: scrollbackURL(id))
            }
        }
    }
}
