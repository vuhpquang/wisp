import AppKit
import GhosttyKit
import SwiftUI

/// Settings changed in the Settings window. They are written as Ghostty config
/// lines to a file only Wisp loads, after the user's own config, so they
/// override it without ever rewriting the user's file. Upstream Ghostty never
/// reads this file, so Wisp-only options here can't break it.
final class WispSettings: ObservableObject {
    static let shared = WispSettings()

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wisp/settings.ghostty")

    /// Options whose value is a list: setting them appends to the list from the
    /// user's config, so an empty value resets it first.
    private static let repeatable: Set<String> = ["font-family"]

    /// The values in the settings file, by option name.
    @Published private(set) var values: [String: String] = [:]

    /// The values in the user's config file, shown as the current value of
    /// options not changed here.
    private(set) var configValues: [String: String] = [:]

    private init() {
        reload()
    }

    /// Re-read both files, e.g. when the Settings window opens.
    func reload() {
        values = Self.parse(try? String(contentsOf: Self.fileURL, encoding: .utf8))
        let configPath = Ghostty.AllocatedString(ghostty_config_open_path()).string
        configValues = Self.parse(try? String(contentsOfFile: configPath, encoding: .utf8))
    }

    /// The value in effect: set here, else in the user's config, else nil for
    /// Ghostty's default.
    func value(_ key: String) -> String? {
        values[key] ?? configValues[key]
    }

    func isOverridden(_ key: String) -> Bool {
        values[key] != nil
    }

    private var pendingSave: DispatchWorkItem?

    /// Set an option, or remove it with nil so the user's config applies again.
    /// Saving waits a moment so dragging a slider reloads the config once.
    func set(_ key: String, _ value: String?) {
        values[key] = value
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: save)
    }

    private func save() {
        var lines = [
            "# Written by the Wisp Settings window. Loaded after your Ghostty config,",
            "# so values here win. Remove a line to use your config's value again.",
            "",
        ]
        for key in values.keys.sorted() {
            if Self.repeatable.contains(key) { lines.append("\(key) = \"\"") }
            lines.append("\(key) = \(values[key]!)")
        }

        do {
            try FileManager.default.createDirectory(
                at: Self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try lines.joined(separator: "\n").appending("\n")
                .write(to: Self.fileURL, atomically: true, encoding: .utf8)
        } catch {
            Ghostty.logger.warning("failed to save settings: \(error.localizedDescription, privacy: .public)")
            return
        }

        (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
    }

    /// Parse `key = value` lines. The last value wins; quotes are removed.
    private static func parse(_ text: String?) -> [String: String] {
        guard let text else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}

// MARK: - Window

final class WispSettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WispSettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Wisp Settings"
        window.contentView = NSHostingView(rootView: WispSettingsView())
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        WispSettings.shared.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Views

struct WispSettingsView: View {
    @ObservedObject private var settings = WispSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }
                window.tabItem { Label("Window", systemImage: "macwindow") }
                terminal.tabItem { Label("Terminal", systemImage: "terminal") }
                tabs.tabItem { Label("Tabs", systemImage: "sidebar.left") }
            }
            .padding(12)

            Divider()

            Text("Changes apply right away. Saved to \(WispSettings.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            HStack {
                Spacer()
                Button("Open Config File") {
                    (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
                }
                Button("Reload Config") {
                    WispSettings.shared.reload()
                    (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
                }
                .help("Apply changes made to the config file. Changes made here apply on their own.")
                Button("Restart Wisp") { WispUpdater.relaunch() }
                    .help("Some options only apply to new windows or after a restart.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 600, height: 560)
    }

    // MARK: Tabs

    private var appearance: some View {
        Form {
            SettingPicker(key: "font-family", title: "Font", options: FontList.monospaced)
            SettingNumber(key: "font-size", title: "Font size", range: 8...32, step: 1, defaultValue: 13)
            SettingPicker(key: "theme", title: "Theme", options: ThemeList.all)
            SettingToggle(key: "font-thicken", title: "Thicken font strokes", defaultValue: false)
            SettingSlider(key: "background-opacity", title: "Background opacity", range: 0.3...1, defaultValue: 1)
            SettingNumber(key: "background-blur-radius", title: "Background blur", range: 0...60, step: 5, defaultValue: 0)
        }
        .formStyle(.grouped)
    }

    private var window: some View {
        Form {
            SettingNumber(key: "window-padding-x", title: "Horizontal padding", range: 0...40, step: 1, defaultValue: 2)
            SettingNumber(key: "window-padding-y", title: "Vertical padding", range: 0...40, step: 1, defaultValue: 2)
            SettingPicker(
                key: "macos-titlebar-style", title: "Titlebar style",
                options: ["native", "transparent", "tabs", "hidden"],
                note: "Applies to new windows.")
            SettingPicker(key: "window-save-state", title: "Restore windows", options: ["default", "never", "always"])
            SettingPicker(key: "macos-option-as-alt", title: "Option as Alt", options: ["false", "true", "left", "right"])
        }
        .formStyle(.grouped)
    }

    private var terminal: some View {
        Form {
            SettingPicker(key: "cursor-style", title: "Cursor style", options: ["block", "bar", "underline", "block_hollow"])
            SettingToggle(key: "cursor-style-blink", title: "Blinking cursor", defaultValue: true)
            SettingNumber(
                key: "scrollback-limit", title: "Scrollback (MB per terminal)",
                range: 1...100, step: 1, defaultValue: 10, scale: 1_000_000)
            SettingToggle(key: "copy-on-select", title: "Copy on select", defaultValue: false)
            SettingPicker(key: "confirm-close-surface", title: "Confirm closing", options: ["true", "false", "always"])
        }
        .formStyle(.grouped)
    }

    private var tabs: some View {
        Form {
            SettingToggle(
                key: "macos-vertical-tabs", title: "Vertical tab sidebar", defaultValue: true,
                note: "Also in the tab menu. ⌘E pins or collapses the sidebar.")
            SettingPicker(key: "notify-on-command-finish", title: "Notify when a command finishes", options: ["never", "unfocused", "always"])
            SettingPicker(
                key: "notify-on-command-finish-action", title: "Notify by",
                options: ["bell", "notify", "bell,notify"])
        }
        .formStyle(.grouped)
    }
}

/// The trailing "reset" button shown for options changed in Settings.
private struct ResetButton: View {
    let key: String
    @ObservedObject private var settings = WispSettings.shared

    var body: some View {
        if settings.isOverridden(key) {
            Button {
                settings.set(key, nil)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.borderless)
            .help("Use the value from your config file")
        }
    }
}

private struct SettingToggle: View {
    let key: String
    let title: String
    let defaultValue: Bool
    var note: String?
    @ObservedObject private var settings = WispSettings.shared

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { settings.value(key).map { $0 == "true" } ?? defaultValue },
                set: { settings.set(key, $0 ? "true" : "false") }
            )) {
                SettingLabel(title: title, note: note)
            }
            ResetButton(key: key)
        }
    }
}

private struct SettingPicker: View {
    let key: String
    let title: String
    let options: [String]
    var note: String?
    @ObservedObject private var settings = WispSettings.shared

    var body: some View {
        HStack {
            Picker(selection: Binding(
                get: { settings.value(key) ?? "" },
                set: { settings.set(key, $0.isEmpty ? nil : $0) }
            )) {
                Text("Default").tag("")
                // Keep a value from the config file selectable even if it isn't listed.
                if let current = settings.value(key), !options.contains(current) {
                    Text(current).tag(current)
                }
                ForEach(options, id: \.self) { Text($0).tag($0) }
            } label: {
                SettingLabel(title: title, note: note)
            }
            ResetButton(key: key)
        }
    }
}

private struct SettingNumber: View {
    let key: String
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    /// The config value is the shown value times this, e.g. bytes for MB.
    var scale: Double = 1
    @ObservedObject private var settings = WispSettings.shared

    var body: some View {
        HStack {
            let value = (settings.value(key).flatMap(Double.init) ?? defaultValue * scale) / scale
            Stepper(value: Binding(
                get: { value },
                set: { settings.set(key, Self.format($0 * scale)) }
            ), in: range, step: step) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(Self.format(value))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            ResetButton(key: key)
        }
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

private struct SettingSlider: View {
    let key: String
    let title: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    @ObservedObject private var settings = WispSettings.shared

    var body: some View {
        HStack {
            let value = settings.value(key).flatMap(Double.init) ?? defaultValue
            Slider(value: Binding(
                get: { value },
                set: { settings.set(key, String(format: "%.2f", $0)) }
            ), in: range) {
                Text(title)
            }
            Text(String(format: "%.0f%%", value * 100))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            ResetButton(key: key)
        }
    }
}

private struct SettingLabel: View {
    let title: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Option lists

private enum FontList {
    /// Installed fixed-pitch font families, computed once.
    static let monospaced: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let member = manager.availableMembers(ofFontFamily: family)?.first,
                  let name = member.first as? String,
                  let font = NSFont(name: name, size: 12) else { return false }
            return font.isFixedPitch
        }
    }()
}

private enum ThemeList {
    /// Themes bundled with the app plus the user's own, computed once.
    static let all: [String] = {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources.appendingPathComponent("ghostty/themes"))
        }
        dirs.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/themes"))
        let names = dirs.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
        return Array(Set(names.filter { !$0.hasPrefix(".") })).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }()
}
