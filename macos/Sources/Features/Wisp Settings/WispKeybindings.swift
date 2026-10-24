import AppKit
import SwiftUI

/// Converts key presses and shortcuts to Ghostty keybind triggers such as
/// `super+shift+t` or `ctrl+arrow_up`.
enum WispTrigger {
    /// Keys that have a name in Ghostty's keybind syntax, by macOS key code.
    private static let namedKeys: [UInt16: String] = [
        36: "enter", 48: "tab", 49: "space", 51: "backspace", 53: "escape", 117: "delete",
        123: "arrow_left", 124: "arrow_right", 125: "arrow_down", 126: "arrow_up",
        115: "home", 119: "end", 116: "page_up", 121: "page_down",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        24: "equal", 27: "minus", 33: "bracket_left", 30: "bracket_right", 42: "backslash",
        41: "semicolon", 39: "quote", 43: "comma", 47: "period", 44: "slash", 50: "grave_accent",
    ]

    private static let namedCharacters: [Character: String] = [
        "=": "equal", "-": "minus", "[": "bracket_left", "]": "bracket_right", "\\": "backslash",
        ";": "semicolon", "'": "quote", ",": "comma", ".": "period", "/": "slash", "`": "grave_accent",
    ]

    /// The trigger for a key press, or nil for a press of only modifiers.
    static func trigger(for event: NSEvent) -> String? {
        let key: String
        if let name = namedKeys[event.keyCode] {
            key = name
        } else if let char = event.characters(byApplyingModifiers: [])?.lowercased().first, char.isLetter || char.isNumber {
            key = String(char)
        } else {
            return nil
        }
        return join(event.modifierFlags.intersection(.deviceIndependentFlagsMask), key)
    }

    /// The trigger for a shortcut read from the config.
    static func trigger(for shortcut: KeyboardShortcut) -> String? {
        let key: String
        switch shortcut.key {
        case .return: key = "enter"
        case .escape: key = "escape"
        case .delete: key = "backspace"
        case .deleteForward: key = "delete"
        case .space: key = "space"
        case .tab: key = "tab"
        case .upArrow: key = "arrow_up"
        case .downArrow: key = "arrow_down"
        case .leftArrow: key = "arrow_left"
        case .rightArrow: key = "arrow_right"
        case .pageUp: key = "page_up"
        case .pageDown: key = "page_down"
        case .home: key = "home"
        case .end: key = "end"
        default:
            let char = Character(shortcut.key.character.lowercased())
            if let name = namedCharacters[char] {
                key = name
            } else if char.isLetter || char.isNumber {
                key = String(char)
            } else {
                return nil
            }
        }

        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        return join(flags, key)
    }

    private static func join(_ flags: NSEvent.ModifierFlags, _ key: String) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("super") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// A trigger written the macOS way, e.g. `⇧⌘T`.
    static func symbols(_ trigger: String) -> String {
        var parts = trigger.replacingOccurrences(of: "global:", with: "").split(separator: "+").map(String.init)
        let key = parts.popLast() ?? ""
        let mods = [("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧"), ("super", "⌘")]
            .filter { parts.contains($0.0) }
            .map(\.1)
            .joined()
        let names = [
            "enter": "⏎", "tab": "⇥", "space": "Space", "backspace": "⌫", "escape": "⎋", "delete": "⌦",
            "arrow_left": "←", "arrow_right": "→", "arrow_down": "↓", "arrow_up": "↑",
            "equal": "=", "minus": "-", "bracket_left": "[", "bracket_right": "]", "backslash": "\\",
            "semicolon": ";", "quote": "'", "comma": ",", "period": ".", "slash": "/", "grave_accent": "`",
            "page_up": "⇞", "page_down": "⇟", "home": "↖", "end": "↘",
        ]
        return mods + (names[key] ?? key.uppercased())
    }
}

// MARK: - Keyboard settings

struct WispKeybindingsView: View {
    @ObservedObject private var settings = WispSettings.shared
    @State private var search = ""
    @State private var recording: String?

    private struct Entry: Identifiable {
        var id: String { action }
        let action: String
        let title: String
    }

    private var entries: [Entry] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        var seen = Set<String>()
        let all = appDelegate.ghostty.config.commandPaletteEntries
            .filter(\.isSupported)
            .compactMap { c -> Entry? in
                guard seen.insert(c.action).inserted else { return nil }
                return Entry(action: c.action, title: c.title)
            }
        let query = search.lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(query) || $0.action.contains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search actions", text: $search)
                .textFieldStyle(.roundedBorder)

            List(entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                        Text(entry.action)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    ShortcutRecorder(action: entry.action, recording: $recording)
                    if settings.hasShortcutOverride(for: entry.action) {
                        Button {
                            settings.resetShortcut(for: entry.action)
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Use the shortcut from your config")
                    }
                }
                .padding(.vertical, 2)
            }

            Text("Click a shortcut and press new keys. Escape cancels, Delete removes the shortcut.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// Shows an action's shortcut. Clicking it records the next key press.
private struct ShortcutRecorder: View {
    let action: String
    @Binding var recording: String?
    @ObservedObject private var settings = WispSettings.shared
    @State private var monitor: Any?

    private var isRecording: Bool { recording == action }

    /// The shortcut in effect, from the reloaded config.
    private var currentTrigger: String? {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let shortcut = appDelegate.ghostty.config.keyboardShortcut(for: action) else { return nil }
        return WispTrigger.trigger(for: shortcut)
    }

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? "Press keys…" : (settings.trigger(for: action) ?? currentTrigger).map(WispTrigger.symbols) ?? "—")
                .font(.system(size: 12, design: .rounded))
                .frame(minWidth: 70)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .onChange(of: recording) { newValue in
            if newValue != action { removeMonitor() }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = action
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // escape
                stop()
            case 51 where event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty: // delete
                settings.setShortcut(for: action, to: nil, replacing: currentTrigger)
                stop()
            default:
                guard let trigger = WispTrigger.trigger(for: event) else { return nil }
                settings.setShortcut(for: action, to: trigger, replacing: currentTrigger)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        removeMonitor()
        if recording == action { recording = nil }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Quick terminal settings

struct WispQuickTerminalSettings: View {
    @ObservedObject private var settings = WispSettings.shared

    private static let action = "toggle_quick_terminal"

    private static let shortcuts: [(trigger: String, label: String)] = [
        ("global:ctrl+grave_accent", "⌃`"),
        ("global:alt+space", "⌥Space"),
        ("global:super+grave_accent", "⌘`"),
        ("global:ctrl+alt+space", "⌃⌥Space"),
        ("global:super+shift+space", "⇧⌘Space"),
    ]

    var body: some View {
        Form {
            Picker(selection: Binding(
                get: { settings.trigger(for: Self.action) ?? "" },
                set: { trigger in
                    if trigger.isEmpty {
                        settings.resetShortcut(for: Self.action)
                    } else {
                        settings.setShortcut(for: Self.action, to: trigger, replacing: nil)
                    }
                }
            )) {
                Text("None").tag("")
                ForEach(Self.shortcuts, id: \.trigger) { Text($0.label).tag($0.trigger) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcut (works in any app)")
                    Text("macOS asks for Accessibility access the first time.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            QuickTerminalOption(key: "quick-terminal-position", title: "Slides in from", options: ["top", "bottom", "left", "right", "center"])
            QuickTerminalOption(key: "quick-terminal-size", title: "Size", options: ["30%", "40%", "50%", "60%", "75%", "100%"])
            QuickTerminalOption(key: "quick-terminal-screen", title: "Screen", options: ["main", "mouse", "macos-menu-bar"])
            QuickTerminalOption(key: "quick-terminal-autohide", title: "Hide when it loses focus", options: ["true", "false"])

            Button("Show Quick Terminal Now") {
                (NSApp.delegate as? AppDelegate)?.toggleQuickTerminal(self)
            }
        }
        .formStyle(.grouped)
    }
}

private struct QuickTerminalOption: View {
    let key: String
    let title: String
    let options: [String]
    @ObservedObject private var settings = WispSettings.shared

    var body: some View {
        Picker(title, selection: Binding(
            get: { settings.value(key) ?? "" },
            set: { settings.set(key, $0.isEmpty ? nil : $0) }
        )) {
            Text("Default").tag("")
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
    }
}
