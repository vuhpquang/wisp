import AppKit
import Combine

/// Updates Wisp from its source checkout. Sparkle is disabled because it would
/// install upstream Ghostty, so instead `scripts/install-wisp.sh` records the
/// commit and checkout it was built from, and this checks that checkout's
/// `origin/main` for new commits, then pulls, rebuilds and reinstalls on request.
final class WispUpdater: ObservableObject {
    static let shared = WispUpdater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(commits: Int, latest: String)
        case updating
        case readyToRestart
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Where the installed app was built from. Nil for builds that weren't
    /// installed by the script, such as debug builds; those never update.
    let sourceURL: URL? = (Bundle.main.infoDictionary?["WispSourcePath"] as? String)
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    private let builtCommit = Bundle.main.infoDictionary?["WispCommit"] as? String

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Wisp/update.log")

    private static let checkInterval: TimeInterval = 6 * 60 * 60
    private var timer: Timer?

    var isSupported: Bool { sourceURL != nil && builtCommit != nil }

    /// Check shortly after launch and then every few hours.
    func start() {
        guard isSupported, timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    /// Look for new commits. A check the user asked for also reports when Wisp
    /// is up to date.
    func check(userInitiated: Bool = false) {
        guard let sourceURL, let builtCommit else {
            if userInitiated {
                state = .failed("This build wasn't installed with scripts/install-wisp.sh, so it can't update itself.")
            }
            return
        }

        switch state {
        case .checking, .updating, .readyToRestart: return
        default: break
        }
        state = .checking

        DispatchQueue.global(qos: .utility).async {
            let result = Result { () -> State in
                try Self.git(["fetch", "--quiet", "origin", "main"], in: sourceURL)
                let count = Int(try Self.git(["rev-list", "--count", "\(builtCommit)..origin/main"], in: sourceURL)) ?? 0
                guard count > 0 else { return .upToDate }
                let latest = try Self.git(["log", "-1", "--format=%s", "origin/main"], in: sourceURL)
                return .available(commits: count, latest: latest)
            }

            DispatchQueue.main.async {
                switch result {
                case .success(.upToDate):
                    self.state = userInitiated ? .upToDate : .idle
                    if userInitiated { self.clearMessage(after: 5) }
                case .success(let state):
                    self.state = state
                case .failure(let error):
                    // Background checks fail quietly, e.g. when offline.
                    self.state = userInitiated ? .failed(error.localizedDescription) : .idle
                }
            }
        }
    }

    /// Pull, rebuild and reinstall. The running app keeps working; restart it
    /// to use the new version.
    func update() {
        guard let sourceURL else { return }
        state = .updating

        DispatchQueue.global(qos: .userInitiated).async {
            let status: Int32
            do {
                try FileManager.default.createDirectory(
                    at: Self.logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
                let log = try FileHandle(forWritingTo: Self.logURL)
                defer { try? log.close() }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [
                    sourceURL.appendingPathComponent("scripts/install-wisp.sh").path,
                    "--pull", "--no-quit",
                ]
                process.currentDirectoryURL = sourceURL
                process.standardOutput = log
                process.standardError = log
                try process.run()
                process.waitUntilExit()
                status = process.terminationStatus
            } catch {
                status = -1
            }

            DispatchQueue.main.async {
                self.state = status == 0
                    ? .readyToRestart
                    : .failed("The update failed. See the log for details.")
            }
        }
    }

    /// Quit and open the newly installed app. Restored windows bring the tabs back.
    func restart() {
        let path = Bundle.main.bundlePath
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while pgrep -f \"$0/Contents/MacOS\" >/dev/null; do sleep 0.5; done; open \"$0\"", path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    func openLog() {
        NSWorkspace.shared.open(Self.logURL)
    }

    func dismiss() {
        state = .idle
    }

    private func clearMessage(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.state == .upToDate { self?.state = .idle }
        }
    }

    struct GitError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    private static func git(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GitError(message: message.isEmpty ? "git \(args.first ?? "") failed" : message)
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
