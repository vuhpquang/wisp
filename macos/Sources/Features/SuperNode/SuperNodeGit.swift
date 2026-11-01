import AppKit
import Combine

/// Runs git for diff nodes.
enum SuperNodeGit {
    struct Result {
        let status: Int32
        let output: String
        let error: String

        var succeeded: Bool { status == 0 }

        /// What to show the user when a command fails.
        var message: String {
            let text = error.isEmpty ? output : error
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs git in `directory` and waits for it. Call this off the main thread.
    static func run(_ arguments: [String], in directory: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // Never wait for a password or passphrase nobody can type.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if environment["GIT_SSH_COMMAND"] == nil { environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        process.environment = environment

        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", error: error.localizedDescription)
        }
        // Read both pipes while git runs so a large output can't fill one and block it.
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = error.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            error: String(decoding: errorData, as: UTF8.self))
    }

    // MARK: Status

    /// A changed file, listed under Staged Changes or Changes.
    struct Change: Hashable, Identifiable {
        let path: String
        /// One letter: M, A, D, R, C, U, or ? for untracked.
        let code: Character
        let staged: Bool

        var id: String { (staged ? "S:" : "W:") + path }
        var isUntracked: Bool { code == "?" }
        var name: String { (path as NSString).lastPathComponent }

        var folder: String {
            let folder = (path as NSString).deletingLastPathComponent
            return folder.isEmpty ? "" : folder
        }

        var color: NSColor {
            switch code {
            case "A", "?": .systemGreen
            case "D": .systemRed
            case "U": .systemOrange
            case "R", "C": .systemBlue
            default: .systemYellow
            }
        }
    }

    struct Status: Equatable {
        var branch: String?
        var ahead = 0
        var behind = 0
        var hasUpstream = false
        var hasCommits = true
        var staged: [Change] = []
        var unstaged: [Change] = []
        var added = 0
        var removed = 0
        var error: String?

        var isClean: Bool { staged.isEmpty && unstaged.isEmpty }
    }

    static func status(in directory: String) -> Status {
        var status = Status()
        let result = run(["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"], in: directory)
        guard result.succeeded else {
            status.error = "Not a git repository"
            return status
        }

        // Entries are separated by NUL. A rename is followed by its old path.
        var entries = result.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            if entry.hasPrefix("## ") {
                parseBranch(String(entry.dropFirst(3)), into: &status)
                continue
            }
            guard entry.count > 3 else { continue }
            let chars = Array(entry.prefix(2))
            let index = chars[0], worktree = chars[1]
            let path = String(entry.dropFirst(3))
            if index == "R" || index == "C" { _ = entries.popFirst() }

            if index == "?" {
                status.unstaged.append(Change(path: path, code: "?", staged: false))
                continue
            }
            if index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") {
                status.unstaged.append(Change(path: path, code: "U", staged: false))
                continue
            }
            if index != " " { status.staged.append(Change(path: path, code: index, staged: true)) }
            if worktree != " " { status.unstaged.append(Change(path: path, code: worktree, staged: false)) }
        }

        let stat = run(["diff", "HEAD", "--shortstat"], in: directory)
        if stat.succeeded {
            status.added = number(before: "insertion", in: stat.output)
            status.removed = number(before: "deletion", in: stat.output)
        }
        return status
    }

    private static func parseBranch(_ header: String, into status: inout Status) {
        // "main...origin/main [ahead 1, behind 2]" or "No commits yet on main"
        if header.hasPrefix("No commits yet on ") {
            status.hasCommits = false
            status.branch = String(header.dropFirst("No commits yet on ".count))
            return
        }
        let parts = header.components(separatedBy: " [")
        let names = parts[0].components(separatedBy: "...")
        status.branch = names[0]
        status.hasUpstream = names.count > 1
        if parts.count > 1 {
            status.ahead = number(after: "ahead ", in: parts[1])
            status.behind = number(after: "behind ", in: parts[1])
        }
    }

    /// The number right before a word, such as 12 in "12 insertions(+)".
    private static func number(before word: String, in text: String) -> Int {
        guard let range = text.range(of: " " + word) else { return 0 }
        let digits = text[..<range.lowerBound].reversed().prefix { $0.isNumber }
        return Int(String(digits.reversed())) ?? 0
    }

    /// The number right after a prefix, such as 2 in "behind 2".
    private static func number(after prefix: String, in text: String) -> Int {
        guard let range = text.range(of: prefix) else { return 0 }
        return Int(String(text[range.upperBound...].prefix { $0.isNumber })) ?? 0
    }

    static func branches(in directory: String) -> [String] {
        run(["branch", "--format=%(refname:short)"], in: directory).output
            .split(separator: "\n").map(String.init)
    }

    // MARK: Patches

    /// Larger patches are cut so the text view stays responsive.
    private static let maxPatchLength = 400_000

    /// The patch for one change, or for everything when `change` is nil.
    static func patch(for change: Change?, in directory: String, hasCommits: Bool) -> String {
        var patch: String
        if let change {
            if change.isUntracked {
                patch = untrackedPatch(change.path, in: directory)
            } else if change.staged {
                patch = run(["diff", "--cached", "--no-color", "--no-ext-diff", "-M", "--", change.path], in: directory).output
            } else {
                patch = run(["diff", "--no-color", "--no-ext-diff", "--", change.path], in: directory).output
            }
        } else if hasCommits {
            patch = run(["diff", "HEAD", "--no-color", "--no-ext-diff", "-M"], in: directory).output
        } else {
            patch = run(["diff", "--cached", "--no-color", "--no-ext-diff"], in: directory).output
        }
        if patch.count > maxPatchLength {
            patch = String(patch.prefix(maxPatchLength)) + "\n… diff truncated …\n"
        }
        return patch
    }

    /// An untracked file shown as a patch that adds every line.
    private static func untrackedPatch(_ path: String, in directory: String) -> String {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "" }
        if data.prefix(8000).contains(0) { return "diff --git a/\(path) b/\(path)\nBinary file\n" }
        let text = String(decoding: data.prefix(maxPatchLength), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return "diff --git a/\(path) b/\(path)\nnew file\n@@ -0,0 +1,\(lines.count) @@\n"
            + lines.map { "+" + $0 }.joined(separator: "\n")
    }

    /// The first line a patch changes in the new file, to open an editor there.
    static func firstChangedLine(in patch: String) -> Int? {
        for line in patch.split(separator: "\n") where line.hasPrefix("@@") {
            // @@ -12,3 +14,5 @@
            guard let plus = line.range(of: " +") else { continue }
            let digits = line[plus.upperBound...].prefix { $0.isNumber }
            if let number = Int(digits) { return max(1, number) }
        }
        return nil
    }

    static func render(patch: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let monoBold = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)

        func append(_ string: String, font: NSFont = mono, color: NSColor, background: NSColor? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let background { attributes[.backgroundColor] = background }
            result.append(NSAttributedString(string: string, attributes: attributes))
        }

        if patch.isEmpty {
            append("No changes.\n", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            return result
        }

        var first = true
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line) + "\n"
            if line.hasPrefix("diff --git") {
                if !first { append("\n", color: .labelColor) }
                first = false
                append(text, font: monoBold, color: .labelColor)
            } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("index ") || line.hasPrefix("new file") {
                append(text, color: .tertiaryLabelColor)
            } else if line.hasPrefix("@@") {
                append(text, color: .systemCyan)
            } else if line.hasPrefix("+") {
                append(text, color: .systemGreen, background: NSColor.systemGreen.withAlphaComponent(0.08))
            } else if line.hasPrefix("-") {
                append(text, color: .systemRed, background: NSColor.systemRed.withAlphaComponent(0.08))
            } else {
                append(text, color: .secondaryLabelColor)
            }
        }
        return result
    }
}

// MARK: - Model

/// The state of a diff node: what changed, what's selected, and the actions
/// that stage, discard and commit.
final class SuperNodeGitModel: ObservableObject {
    @Published private(set) var status = SuperNodeGit.Status()
    @Published private(set) var branches: [String] = []
    @Published private(set) var selection: SuperNodeGit.Change?
    @Published private(set) var patch = NSAttributedString()
    /// Changes when the shown patch is for something else, so the view
    /// scrolls back to the top.
    @Published private(set) var patchID = UUID()
    @Published var commitMessage = ""
    /// The last error or result, such as a failed push.
    @Published var message: String?
    @Published private(set) var isBusy = false

    private(set) var directory: String?
    private var patchText = ""
    private var refreshing = false
    /// Set when a refresh is asked for while one runs, so the newer state isn't missed.
    private var refreshAgain = false
    /// Git commands run one at a time, in order.
    private let queue = DispatchQueue(label: "com.vuhpquang.wisp.supernode.git")

    func setDirectory(_ directory: String?) {
        guard directory != self.directory else { return }
        self.directory = directory
        selection = nil
        status = SuperNodeGit.Status()
        patchText = ""
        patch = NSAttributedString()
        patchID = UUID()
        refresh()
    }

    /// Reloads the status and the shown patch, updating only what changed.
    func refresh() {
        guard let directory else { return }
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        let selection = selection
        queue.async { [weak self] in
            let status = SuperNodeGit.status(in: directory)
            // Keep the selection if the file is still changed.
            let all = status.staged + status.unstaged
            let kept = selection.flatMap { all.contains($0) ? $0 : nil }
            let patch = status.error == nil
                ? SuperNodeGit.patch(for: kept, in: directory, hasCommits: status.hasCommits)
                : ""
            let branches = status.error == nil ? SuperNodeGit.branches(in: directory) : []
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
                guard directory == self.directory else { return }
                if status != self.status { self.status = status }
                if branches != self.branches { self.branches = branches }
                if kept != self.selection { self.selection = kept }
                self.showPatch(patch, newTarget: kept != selection)
            }
        }
    }

    private func showPatch(_ text: String, newTarget: Bool) {
        guard text != patchText || newTarget else { return }
        patchText = text
        patch = SuperNodeGit.render(patch: text)
        if newTarget { patchID = UUID() }
    }

    /// Shows the patch of one change, or of everything when nil.
    func select(_ change: SuperNodeGit.Change?) {
        guard let directory else { return }
        selection = change
        let hasCommits = status.hasCommits
        queue.async { [weak self] in
            let patch = SuperNodeGit.patch(for: change, in: directory, hasCommits: hasCommits)
            DispatchQueue.main.async {
                guard let self, self.selection == change else { return }
                self.patchText = patch
                self.patch = SuperNodeGit.render(patch: patch)
                self.patchID = UUID()
            }
        }
    }

    /// The patch text of a change, to find the line to open an editor at.
    func patchText(for change: SuperNodeGit.Change, completion: @escaping (String) -> Void) {
        guard let directory else { return }
        let hasCommits = status.hasCommits
        queue.async {
            let patch = SuperNodeGit.patch(for: change, in: directory, hasCommits: hasCommits)
            DispatchQueue.main.async { completion(patch) }
        }
    }

    // MARK: Actions

    func stage(_ changes: [SuperNodeGit.Change]) {
        let paths = changes.map(\.path)
        guard !paths.isEmpty else { return }
        perform(["add", "-A", "--"] + paths)
    }

    func unstage(_ changes: [SuperNodeGit.Change]) {
        let paths = changes.map(\.path)
        guard !paths.isEmpty else { return }
        if status.hasCommits {
            perform(["restore", "--staged", "--"] + paths)
        } else {
            perform(["rm", "--cached", "-r", "--quiet", "--"] + paths)
        }
    }

    /// Throws away unstaged changes. Untracked files go to the Trash so they
    /// can be recovered.
    func discard(_ changes: [SuperNodeGit.Change]) {
        guard let directory else { return }
        let tracked = changes.filter { !$0.isUntracked }.map(\.path)
        let untracked = changes.filter(\.isUntracked).map {
            URL(fileURLWithPath: directory).appendingPathComponent($0.path)
        }
        for url in untracked {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                message = "Couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)"
            }
        }
        if tracked.isEmpty {
            refresh()
        } else {
            perform(["restore", "--worktree", "--"] + tracked)
        }
    }

    func commit(stagingAll: Bool = false) {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            self.message = "Write a commit message first."
            return
        }
        if stagingAll {
            perform(["add", "-A"]) { [weak self] in self?.runCommit(message) }
        } else {
            runCommit(message)
        }
    }

    private func runCommit(_ text: String) {
        perform(["commit", "-m", text]) { [weak self] in
            self?.commitMessage = ""
            self?.message = nil
        }
    }

    func push() {
        if status.hasUpstream {
            perform(["push"], success: "Pushed.")
        } else {
            perform(["push", "--set-upstream", "origin", "HEAD"], success: "Pushed and set the upstream branch.")
        }
    }

    func pull() {
        perform(["pull", "--ff-only"], success: "Pulled.")
    }

    func checkout(_ branch: String) {
        perform(["switch", branch])
    }

    func createBranch(_ name: String) {
        perform(["switch", "-c", name])
    }

    /// Runs a git command that changes the repository, then refreshes.
    private func perform(_ arguments: [String], success: String? = nil, then: (() -> Void)? = nil) {
        guard let directory else { return }
        isBusy = true
        queue.async { [weak self] in
            let result = SuperNodeGit.run(arguments, in: directory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                if result.succeeded {
                    if let success { self.message = success }
                    then?()
                } else {
                    self.message = result.message.isEmpty ? "git \(arguments.first ?? "") failed" : result.message
                }
                self.refresh()
            }
        }
    }
}
