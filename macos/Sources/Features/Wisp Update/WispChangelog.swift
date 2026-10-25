import AppKit
import SwiftUI

/// "What's New" after Wisp updates itself: the sections of CHANGELOG.md newer
/// than the version that ran before the update. `scripts/install-wisp.sh`
/// copies CHANGELOG.md into the app and takes the app's version from it.
enum WispChangelog {
    struct Release: Identifiable, Equatable {
        var id: String { version }
        let version: String
        let date: String?
        /// The section's markdown lines, without the version heading.
        let lines: [String]
    }

    /// Set by the updater once an update is installed: the version it replaced.
    static let updatedFromKey = "WispChangelogUpdatedFrom"
    private static let lastRunKey = "WispLastRunVersion"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// At launch: show what's new if this launch follows an update.
    static func showIfUpdated() {
        guard WispUpdater.shared.isSupported else { return }
        let defaults = UserDefaults.ghostty
        let lastRun = defaults.string(forKey: lastRunKey)
        defaults.set(currentVersion, forKey: lastRunKey)

        var from = defaults.string(forKey: updatedFromKey)
        defaults.removeObject(forKey: updatedFromKey)
        // 0.1.0 didn't record the update yet. A fresh update log and no version
        // from an earlier launch means this is the first launch after it.
        if from == nil, lastRun == nil, updatedRecently() { from = "0.1.0" }

        guard let from, compare(from, currentVersion) == .orderedAscending else { return }
        let releases = load().filter { compare($0.version, from) == .orderedDescending }
        guard !releases.isEmpty else { return }

        // After the first window, so it shows on top of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            WispChangelogWindowController.shared.show(releases)
        }
    }

    private static func updatedRecently() -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: WispUpdater.logURL.path)
        guard let modified = attributes?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < 24 * 60 * 60
    }

    /// CHANGELOG.md from the app, or from the checkout it was built from.
    static func load() -> [Release] {
        let urls = [
            Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
            WispUpdater.shared.sourceURL?.appendingPathComponent("CHANGELOG.md"),
        ]
        for case let url? in urls {
            if let text = try? String(contentsOf: url, encoding: .utf8) { return parse(text) }
        }
        return []
    }

    /// Sections start with `## <version>` or `## <version> - <date>`.
    static func parse(_ markdown: String) -> [Release] {
        var releases: [Release] = []
        var heading: (version: String, date: String?)?
        var lines: [String] = []

        func flush() {
            guard let heading else { return }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            releases.append(Release(version: heading.version, date: heading.date, lines: lines))
        }

        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                flush()
                let parts = line.dropFirst(3).components(separatedBy: " - ")
                heading = (parts[0].trimmingCharacters(in: .whitespaces), parts.count > 1 ? parts[1] : nil)
                lines = []
            } else if heading != nil {
                if lines.isEmpty && line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                lines.append(line)
            }
        }
        flush()
        return releases
    }

    /// Numeric comparison where "0.1" equals "0.1.0".
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

final class WispChangelogWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WispChangelogWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "What's New in Wisp"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 360)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ releases: [WispChangelog.Release]) {
        guard let window else { return }
        window.contentView = NSHostingView(rootView: WispChangelogView(releases: releases) { [weak window] in
            window?.close()
        })
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

struct WispChangelogView: View {
    let releases: [WispChangelog.Release]
    let close: () -> Void

    private static let releasesURL = URL(string: "https://github.com/vuhpquang/wisp/releases")!

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wisp is up to date")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Version \(WispChangelog.currentVersion). Here's what's new.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(releases) { release in
                        WispChangelogSection(release: release)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }

            Divider()

            HStack {
                Link("All releases on GitHub", destination: Self.releasesURL)
                Spacer()
                Button("Continue", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}

/// One release: its version, then its `###` headings, `-` items and text.
private struct WispChangelogSection: View {
    let release: WispChangelog.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(release.version)
                    .font(.system(size: 15, weight: .bold))
                if let date = release.date {
                    Text(date)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, 8)
                case .item(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                case .text(let text):
                    Text(Self.inline(text))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 13))
        .textSelection(.enabled)
    }

    private enum Block {
        case heading(String)
        case item(String)
        case text(String)
    }

    /// Lines folded into blocks: an item's wrapped lines join the item.
    private var blocks: [Block] {
        var blocks: [Block] = []
        for raw in release.lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("### ") {
                blocks.append(.heading(String(line.dropFirst(4))))
            } else if line.hasPrefix("- ") {
                blocks.append(.item(String(line.dropFirst(2))))
            } else if raw.hasPrefix("  "), case .item(let text) = blocks.last {
                blocks[blocks.count - 1] = .item(text + " " + line)
            } else if case .text(let text) = blocks.last {
                blocks[blocks.count - 1] = .text(text + " " + line)
            } else {
                blocks.append(.text(line))
            }
        }
        return blocks
    }

    private static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}
