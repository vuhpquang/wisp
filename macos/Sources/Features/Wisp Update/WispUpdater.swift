import AppKit
import Combine

/// Updates Wisp. Sparkle is disabled because it would install upstream Ghostty.
/// Instead there are two kinds of builds:
/// - Built from a checkout: `scripts/install-wisp.sh` records the commit and
///   checkout, and this checks that checkout's `origin/main` for new commits,
///   then pulls, rebuilds and reinstalls on request.
/// - Downloaded from GitHub: `scripts/release-wisp.sh` records the repo, and
///   this checks its latest release, then downloads it and replaces the app.
final class WispUpdater: ObservableObject {
    static let shared = WispUpdater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        /// `summary` describes the update, e.g. the latest commit or release.
        case available(summary: String)
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
    /// The GitHub repo ("owner/name") whose releases update a downloaded build.
    private let releaseRepo = Bundle.main.infoDictionary?["WispReleaseRepo"] as? String
    /// The zip of the newer release, found by the last check.
    private var releaseZipURL: URL?

    /// Whether an update rebuilds from the checkout (slow) or downloads a release.
    var buildsFromSource: Bool { sourceURL != nil && builtCommit != nil }

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Wisp/update.log")

    private static let checkInterval: TimeInterval = 6 * 60 * 60
    private var timer: Timer?

    var isSupported: Bool { buildsFromSource || releaseRepo != nil }

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
        guard isSupported else {
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
                if let sourceURL = self.sourceURL, let builtCommit = self.builtCommit {
                    return try Self.checkCheckout(sourceURL, builtCommit: builtCommit)
                }
                return try self.checkReleases()
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

    private static func checkCheckout(_ sourceURL: URL, builtCommit: String) throws -> State {
        try git(["fetch", "--quiet", "origin", "main"], in: sourceURL)
        let count = Int(try git(["rev-list", "--count", "\(builtCommit)..origin/main"], in: sourceURL)) ?? 0
        guard count > 0 else { return .upToDate }
        let latest = try git(["log", "-1", "--format=%s", "origin/main"], in: sourceURL)
        return .available(summary: count == 1 ? latest : "\(count) changes · \(latest)")
    }

    /// Compare the latest GitHub release, tagged `wisp-v<version>`, with this
    /// app's version. Runs off the main thread.
    private func checkReleases() throws -> State {
        guard let releaseRepo,
              let url = URL(string: "https://api.github.com/repos/\(releaseRepo)/releases/latest")
        else { return .upToDate }

        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let assets: [Asset]
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let release = try JSONDecoder().decode(Release.self, from: try Self.fetch(request))

        let version = release.tag_name.replacingOccurrences(of: "wisp-v", with: "")
        guard WispChangelog.compare(WispChangelog.currentVersion, version) == .orderedAscending,
              let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") })
        else { return .upToDate }

        DispatchQueue.main.async { self.releaseZipURL = zip.browser_download_url }
        return .available(summary: "Wisp \(version)")
    }

    /// Install the update. The running app keeps working; restart it to use
    /// the new version.
    func update() {
        state = .updating
        let zipURL = releaseZipURL

        DispatchQueue.global(qos: .userInitiated).async {
            let succeeded: Bool
            if let sourceURL = self.sourceURL, self.buildsFromSource {
                succeeded = Self.rebuild(from: sourceURL)
            } else if let zipURL {
                succeeded = Self.install(zipURL)
            } else {
                succeeded = false
            }

            DispatchQueue.main.async {
                if succeeded {
                    // The new version shows what's new on its first launch.
                    UserDefaults.ghostty.set(WispChangelog.currentVersion, forKey: WispChangelog.updatedFromKey)
                    self.state = .readyToRestart
                } else {
                    self.state = .failed("The update failed. See the log for details.")
                }
            }
        }
    }

    /// Pull, rebuild and reinstall with the install script.
    private static func rebuild(from sourceURL: URL) -> Bool {
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
        return status == 0
    }

    /// Download a release's zip and put its Wisp.app where this app is.
    private static func install(_ zipURL: URL) -> Bool {
        var log = ""
        defer {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? log.write(to: logURL, atomically: true, encoding: .utf8)
        }

        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL
        do {
            // macOS runs a quarantined app opened from Downloads from a
            // read-only copy, which can't be replaced.
            guard !appURL.path.contains("/AppTranslocation/") else {
                throw UpdateError(message: "Move Wisp.app to the Applications folder, open it from there and update again.")
            }

            log += "Downloading \(zipURL.absoluteString)\n"
            let zip = try fetch(URLRequest(url: zipURL))

            // On the app's volume, so the replacement is a rename.
            let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                  appropriateFor: appURL, create: true)
            defer { try? fm.removeItem(at: work) }
            let zipFile = work.appendingPathComponent("Wisp.zip")
            try zip.write(to: zipFile)

            log += "Unzipping\n"
            try run("/usr/bin/ditto", ["-x", "-k", zipFile.path, work.path])
            let newApp = work.appendingPathComponent("Wisp.app")
            try run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            log += "Replacing \(appURL.path)\n"
            _ = try fm.replaceItemAt(appURL, withItemAt: newApp)
            log += "Done\n"
            return true
        } catch {
            log += "Failed: \(error.localizedDescription)\n"
            return false
        }
    }

    /// Quit and open the newly installed app. Restored windows bring the tabs back.
    func restart() {
        Self.relaunch()
    }

    /// Quit Wisp and open it again once it has exited.
    static func relaunch() {
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

    /// Download synchronously; called off the main thread.
    private static func fetch(_ request: URLRequest) throws -> Data {
        var result: Result<Data, Error> = .failure(UpdateError(message: "No response"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(UpdateError(message: "\(request.url?.absoluteString ?? "") returned \(http.statusCode)"))
            } else {
                result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        try process.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdateError(message: message.isEmpty ? "\(tool) failed" : message)
        }
    }

    struct UpdateError: LocalizedError {
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
            throw UpdateError(message: message.isEmpty ? "git \(args.first ?? "") failed" : message)
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
