import AppKit
import Combine
import SwiftUI

/// A terminal running a coding agent such as Claude Code, as shown in the
/// Agent Monitor.
struct AgentSession: Identifiable, Equatable {
    enum Status: Int, Comparable {
        case needsInput, error, working, idle

        static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .needsInput: "Needs input"
            case .error: "Error"
            case .working: "Working"
            case .idle: "Idle"
            }
        }

        var color: Color {
            switch self {
            case .needsInput: .orange
            case .error: .red
            case .working: .accentColor
            case .idle: .secondary
            }
        }
    }

    let id: ObjectIdentifier
    let title: String
    let status: Status
    let directory: String?
    let branch: String?
    let workspace: TabWorkspace?
    let runningSince: Date?
    weak var surface: Ghostty.SurfaceView?
    weak var window: NSWindow?

    static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.status == rhs.status
            && lhs.directory == rhs.directory && lhs.branch == rhs.branch
            && lhs.workspace == rhs.workspace && lhs.runningSince == rhs.runningSince
    }
}

/// Finds agent sessions in every terminal, refreshing while the monitor is open.
final class AgentMonitorModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    private var timer: Timer?

    /// Words in a terminal title that identify a coding agent.
    private static let agentNames = ["claude", "codex", "gemini", "aider", "opencode", "cursor-agent", "amp", "copilot"]

    /// Claude Code puts a spinner or star at the start of its title.
    private static let agentMarkers: Set<Character> = ["✳", "✶", "✻", "✽", "✢", "·", "*"]

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        var found: [AgentSession] = []
        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            for surface in controller.surfaceTree {
                guard Self.isAgent(surface) else { continue }
                found.append(Self.session(for: surface, in: window, controller: controller))
            }
        }
        found.sort { ($0.status, $0.title) < ($1.status, $1.title) }
        if found != sessions { sessions = found }
    }

    private static func isAgent(_ surface: Ghostty.SurfaceView) -> Bool {
        let title = surface.title.trimmingCharacters(in: .whitespaces)
        if let first = title.first, agentMarkers.contains(first) || isSpinner(first) { return true }
        let lowered = title.lowercased()
        return agentNames.contains { lowered.contains($0) }
    }

    private static func isSpinner(_ char: Character) -> Bool {
        // Braille spinners used by most CLIs: ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
        char.unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } ?? false
    }

    private static func session(
        for surface: Ghostty.SurfaceView,
        in window: NSWindow,
        controller: BaseTerminalController
    ) -> AgentSession {
        let title = surface.title.isEmpty ? window.title : surface.title
        let report = surface.progressReport
        let command = TabCommandTracker.shared.state(of: surface)

        let status: AgentSession.Status
        if report?.state == .error {
            status = .error
        } else if surface.bell {
            status = .needsInput
        } else if let report, report.state != .remove {
            status = .working
        } else if let first = title.first, isSpinner(first) {
            status = .working
        } else {
            status = .idle
        }

        let pwd = surface.pwd.flatMap { $0.isEmpty ? nil : $0 }
        let store = TabWorkspaceStore.shared
        let workspaceID = store.workspaceID(of: window)
        var runningSince: Date?
        if case .running(let since) = command { runningSince = since }

        return AgentSession(
            id: ObjectIdentifier(surface),
            title: title,
            status: status,
            directory: pwd.map { ($0 as NSString).abbreviatingWithTildeInPath },
            branch: pwd.flatMap(TabGitInfo.branch(at:)),
            workspace: store.workspaces.first { $0.id == workspaceID },
            runningSince: runningSince,
            surface: surface,
            window: window)
    }

    /// Bring a session's tab and split to the front.
    func focus(_ session: AgentSession) {
        guard let window = session.window else { return }
        if let workspace = session.workspace { TabWorkspaceStore.shared.activate(workspace.id) }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        if let surface = session.surface,
           let controller = window.windowController as? BaseTerminalController {
            controller.focusSurface(surface)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Window

final class AgentMonitorWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AgentMonitorWindowController()

    private let model = AgentMonitorModel()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false)
        window.title = "Agent Monitor"
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AgentMonitorView(model: model))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggle() {
        if window?.isVisible == true {
            window?.close()
        } else {
            model.start()
            showWindow(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}

// MARK: - Views

struct AgentMonitorView: View {
    @ObservedObject var model: AgentMonitorModel

    var body: some View {
        Group {
            if model.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No agents running")
                        .font(.headline)
                    Text("Terminals running Claude Code, Codex, Gemini or Aider show up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.sessions) { session in
                    AgentRow(session: session) { model.focus(session) }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 360, minHeight: 240)
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let onFocus: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let workspace = session.workspace {
                        TabIcon(icon: workspace.icon)
                        Text(workspace.name)
                        Text("·")
                    }
                    if let directory = session.directory {
                        Text((directory as NSString).lastPathComponent)
                    }
                    if let branch = session.branch {
                        Text("· \(branch)")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(session.status.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(session.status.color)
                if let since = session.runningSince {
                    Text(Date().timeIntervalSince(since).compactDuration)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }

            Button("Go", action: onFocus)
                .controlSize(.small)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onFocus)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.status {
        case .working:
            ProgressView().controlSize(.small)
        case .needsInput:
            Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .idle:
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
        }
    }
}
