import Foundation

extension Notification.Name {
    /// A command started or finished in a surface. See `TabCommandTracker`.
    static let tabCommandStateDidChange = Notification.Name("com.mitchellh.ghostty.tabCommandStateDidChange")

    /// A surface's working directory changed.
    static let ghosttySurfacePwdDidChange = Notification.Name("com.mitchellh.ghostty.surfacePwdDidChange")
}

/// The state of the last command run in a surface, from shell integration.
enum TabCommandState: Equatable {
    case running(since: Date)
    case finished(at: Date, exitCode: Int?, duration: TimeInterval)
}

/// Remembers the command state of every surface for the tab sidebar.
final class TabCommandTracker {
    static let shared = TabCommandTracker()

    private let states = NSMapTable<Ghostty.SurfaceView, Box>.weakToStrongObjects()

    private final class Box {
        let state: TabCommandState
        init(_ state: TabCommandState) { self.state = state }
    }

    func state(of surface: Ghostty.SurfaceView) -> TabCommandState? {
        states.object(forKey: surface)?.state
    }

    func started(_ surface: Ghostty.SurfaceView) {
        set(.running(since: Date()), for: surface)
    }

    func finished(_ surface: Ghostty.SurfaceView, exitCode: Int?, duration: TimeInterval) {
        set(.finished(at: Date(), exitCode: exitCode, duration: duration), for: surface)
    }

    private func set(_ state: TabCommandState, for surface: Ghostty.SurfaceView) {
        states.setObject(Box(state), forKey: surface)
        NotificationCenter.default.post(name: .tabCommandStateDidChange, object: surface)
    }
}

/// Finds the git branch of a directory by reading `.git/HEAD` directly, which
/// is cheap enough to do on every sidebar reload.
enum TabGitInfo {
    /// The git directory for each working directory we've looked up.
    private static var gitDirCache: [String: URL?] = [:]

    /// The branch read from each HEAD file and the file's modification date.
    private static var branchCache: [String: (modified: Date?, branch: String?)] = [:]

    static func branch(at path: String) -> String? {
        guard let gitDir = gitDir(for: path) else { return nil }
        let headPath = gitDir.appendingPathComponent("HEAD").path

        // Only re-read HEAD when it changed, e.g. after `git checkout`.
        let modified = (try? FileManager.default.attributesOfItem(atPath: headPath))?[.modificationDate] as? Date
        if let cached = branchCache[headPath], cached.modified == modified { return cached.branch }

        let branch = readBranch(headPath)
        branchCache[headPath] = (modified, branch)
        return branch
    }

    private static func readBranch(_ headPath: String) -> String? {
        guard let head = try? String(contentsOfFile: headPath, encoding: .utf8) else { return nil }

        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: refs/heads/"
        if trimmed.hasPrefix(refPrefix) {
            return String(trimmed.dropFirst(refPrefix.count))
        }

        // Detached HEAD: show the short commit hash.
        return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
    }

    private static func gitDir(for path: String) -> URL? {
        if let cached = gitDirCache[path] { return cached }

        var result: URL?
        var dir = URL(fileURLWithPath: path, isDirectory: true)
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    result = dotGit
                } else if let contents = try? String(contentsOf: dotGit, encoding: .utf8),
                          contents.hasPrefix("gitdir: ") {
                    // Worktrees and submodules point to their git directory.
                    let target = contents.dropFirst("gitdir: ".count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    result = URL(fileURLWithPath: target, relativeTo: dir).standardizedFileURL
                }
                break
            }

            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        gitDirCache[path] = result
        return result
    }
}

extension TimeInterval {
    /// A compact duration such as `45s`, `3m`, `1h 5m`.
    var compactDuration: String {
        let seconds = Int(self)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
