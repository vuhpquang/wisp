import AppKit

/// The uncommitted changes of a git repository, as shown in a diff node.
struct SuperNodeGitDiff: Equatable {
    struct File: Equatable {
        /// Two-letter status from `git status --porcelain`, such as " M" or "??".
        let status: String
        let path: String
    }

    var branch: String?
    var files: [File] = []
    var patch: String = ""
    var error: String?

    var added: Int {
        patch.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
    }

    var removed: Int {
        patch.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
    }

    /// Larger patches are cut so the text view stays responsive.
    private static let maxPatchLength = 400_000

    /// Runs git in `directory`. Call this off the main thread.
    static func load(directory: String) -> SuperNodeGitDiff {
        var diff = SuperNodeGitDiff()

        guard let status = git(["status", "--porcelain=v1", "--branch", "--untracked-files=all"], in: directory) else {
            diff.error = "Not a git repository"
            return diff
        }

        for line in status.split(separator: "\n") {
            if line.hasPrefix("## ") {
                let header = line.dropFirst(3)
                diff.branch = header.components(separatedBy: "...").first
                    .map { $0.replacingOccurrences(of: "No commits yet on ", with: "") }
                continue
            }
            guard line.count > 3 else { continue }
            let code = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            // Renames are listed as "old -> new".
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            diff.files.append(File(status: code, path: unquote(path)))
        }

        // Staged and unstaged changes together, compared with the last commit.
        // A repository without commits has no HEAD, so fall back to the index.
        var patch = git(["diff", "HEAD", "--no-color", "--no-ext-diff", "-M"], in: directory)
            ?? git(["diff", "--no-color", "--no-ext-diff"], in: directory)
            ?? ""
        if patch.count > maxPatchLength {
            patch = String(patch.prefix(maxPatchLength)) + "\n… diff truncated …\n"
        }
        diff.patch = patch
        return diff
    }

    /// git quotes paths with spaces or special characters: "a b.txt".
    private static func unquote(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        return String(path.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func git(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Rendering

    /// Links in the file list jump to that file's patch.
    static let fileLinkScheme = "supernode-file"

    func attributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let monoBold = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        let body = NSFont.systemFont(ofSize: 12)

        func append(_ string: String, font: NSFont = mono, color: NSColor = .labelColor, link: String? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let link { attributes[.link] = link }
            result.append(NSAttributedString(string: string, attributes: attributes))
        }

        if let error {
            append(error + "\n", font: body, color: .secondaryLabelColor)
            return result
        }

        if files.isEmpty {
            append("No changes. The working tree is clean.\n", font: body, color: .secondaryLabelColor)
            return result
        }

        for file in files {
            append(file.status.replacingOccurrences(of: " ", with: "·") + "  ", color: Self.statusColor(file.status))
            append(file.path + "\n", color: .linkColor, link: "\(Self.fileLinkScheme):\(file.path)")
        }
        append("\n")

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line) + "\n"
            if line.hasPrefix("diff --git") {
                append("\n")
                append(text, font: monoBold, color: .labelColor)
            } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("index ") {
                append(text, color: .tertiaryLabelColor)
            } else if line.hasPrefix("@@") {
                append(text, color: .systemCyan)
            } else if line.hasPrefix("+") {
                append(text, color: .systemGreen)
            } else if line.hasPrefix("-") {
                append(text, color: .systemRed)
            } else {
                append(text, color: .secondaryLabelColor)
            }
        }

        let untracked = files.filter { $0.status == "??" }
        if !untracked.isEmpty {
            append("\nUntracked files\n", font: monoBold)
            for file in untracked { append("  \(file.path)\n", color: .systemGreen) }
        }
        return result
    }

    private static func statusColor(_ status: String) -> NSColor {
        if status == "??" || status.contains("A") { return .systemGreen }
        if status.contains("D") { return .systemRed }
        if status.contains("U") { return .systemOrange }
        return .systemYellow
    }
}
