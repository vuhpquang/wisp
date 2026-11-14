import SwiftUI

/// Wisp's About window: its own icon, what it is, who makes it and a way to
/// check for updates. Replaces upstream's AboutView (see AboutController), so
/// that file can keep merging cleanly.
struct WispAboutView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var updater = WispUpdater.shared

    private static let repoURL = URL(string: "https://github.com/vuhpquang/wisp")!
    // Author identity: copied from app-shell's `Author` (github.com/vuhpquang/app-shell,
    // Sources/AppShellCore/Author.swift). Wisp doesn't link the package (upstream merges stay
    // clean), so keep these in sync by hand — hub rule `.claude/rules/app-shell.md`.
    private static let authorName = "Ha Phung Quang Vu"
    private static let authorURL = URL(string: "https://vuhpquang.com")!
    private static let githubURL = URL(string: "https://github.com/vuhpquang")!
    private static let linkedInURL = URL(string: "https://www.linkedin.com/in/vuhpquang/")!
    private static let copyright = "© 2026 Ha Phung Quang Vu"
    private static let ghosttyURL = URL(string: "https://github.com/ghostty-org/ghostty")!

    private let info = Bundle.main.infoDictionary ?? [:]
    private var version: String? { info["CFBundleShortVersionString"] as? String }
    private var build: String? { info["CFBundleVersion"] as? String }
    /// The Wisp commit the app was built from, written by scripts/install-wisp.sh.
    private var commit: String? {
        (info["WispCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            ghosttyIconImage()
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)
                .accessibilityLabel("Wisp Application Icon")

            VStack(spacing: 6) {
                Text("Wisp")
                    .font(.system(size: 26, weight: .bold))
                Text("A fast, native macOS terminal with vertical tabs,\nworkspaces and an eye on your coding agents.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)
            .textSelection(.enabled)

            versionBlock
                .padding(.top, 18)

            updateBlock
                .padding(.top, 16)

            HStack(spacing: 8) {
                Button {
                    openURL(Self.repoURL)
                } label: {
                    Text("GitHub")
                }
                Button {
                    WispChangelogWindowController.shared.show(WispChangelog.load())
                } label: {
                    Text("What's New")
                }
                Button {
                    openURL(Self.repoURL.appendingPathComponent("issues/new"))
                } label: {
                    Text("Report Issue")
                }
            }
            .controlSize(.regular)
            .padding(.top, 18)

            Divider()
                .padding(.vertical, 18)

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text("Made by")
                        .foregroundStyle(.secondary)
                    Link(Self.authorName, destination: Self.authorURL)
                }
                HStack(spacing: 6) {
                    Link("vuhpquang.com", destination: Self.authorURL)
                    Text("·").foregroundStyle(.tertiary)
                    Link("GitHub", destination: Self.githubURL)
                    Text("·").foregroundStyle(.tertiary)
                    Link("LinkedIn", destination: Self.linkedInURL)
                    Text("·").foregroundStyle(.tertiary)
                    Link("Source code", destination: Self.repoURL)
                }
                HStack(spacing: 4) {
                    Text("Built on")
                    Link("Ghostty", destination: Self.ghosttyURL)
                    Text("by Mitchell Hashimoto")
                }
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
                Text(Self.copyright)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: 380)
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    // MARK: - Version

    private var versionBlock: some View {
        VStack(spacing: 3) {
            if let version {
                row("Version", version, url: Self.repoURL.appendingPathComponent("releases"))
            }
            if let build {
                row("Build", build)
            }
            if let commit {
                row("Commit", String(commit.prefix(9)), url: Self.repoURL.appendingPathComponent("commit/\(commit)"))
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String, url: URL? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Group {
                if let url {
                    Link(value, destination: url)
                } else {
                    Text(value)
                }
            }
            .monospaced()
            .frame(width: 110, alignment: .leading)
        }
    }

    // MARK: - Updates

    @ViewBuilder
    private var updateBlock: some View {
        VStack(spacing: 6) {
            switch updater.state {
            case .available:
                Button("Update Now") { updater.update() }
                    .buttonStyle(.borderedProminent)
            case .readyToRestart:
                Button("Restart to Update") { updater.restart() }
                    .buttonStyle(.borderedProminent)
            default:
                Button {
                    updater.check(userInitiated: true)
                } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(updater.state == .checking || updater.state == .updating)
            }

            statusText
                .font(.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 14)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch updater.state {
        case .idle:
            Text(" ")
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("Wisp is up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .available(let summary):
            Text("New version: \(summary)")
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .updating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(updater.buildsFromSource ? "Building the new version…" : "Downloading…")
                    .foregroundStyle(.secondary)
            }
        case .readyToRestart:
            Text("The new version is installed.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    // MARK: - Background

    /// The translucent background of Apple's own About windows.
    private struct VisualEffectBackground: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .underWindowBackground
            view.blendingMode = .behindWindow
            view.autoresizingMask = [.width, .height]
            return view
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }
}
