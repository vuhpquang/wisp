import AppKit
import Combine
import SwiftUI

/// Samples every process, and what SuperNode uses, while the Process Monitor
/// is open.
final class ProcessMonitorModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case processes = "Processes"
        case superNode = "SuperNode"
        var id: String { rawValue }
    }

    @Published var tab: Tab = .processes
    @Published private(set) var processes: [ProcessSample] = []
    @Published private(set) var memory = SystemMemory()
    @Published private(set) var superNode = SuperNodeUsage()
    @Published private(set) var isRunning = false

    private let queue = DispatchQueue(label: "com.wisp.process-monitor", qos: .utility)
    private let sampler = ProcessSampler()
    private var timer: Timer?
    private var sampling = false
    private var savedNodes: [UUID: (title: String, project: String, kind: SuperNodeItem.Kind)] = [:]
    private var savedNodesRead = Date.distantPast

    static let interval: TimeInterval = 2

    func start() {
        guard timer == nil else { return }
        isRunning = true
        refresh()
        // CPU needs two samples; take the second soon so figures show quickly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func refresh() {
        guard !sampling else { return }
        sampling = true
        var roots = SuperNodeUsageRoots.current(savedNodes: savedNodes)
        let readSaved = Date().timeIntervalSince(savedNodesRead) > 30
        queue.async { [weak self] in
            guard let self else { return }
            let samples = self.sampler.sample()
            if readSaved { roots.savedNodes = SuperNodeUsageRoots.loadSavedNodes() }
            let usage = SuperNodeUsage.measure(roots, samples: samples)
            let memory = ProcessSampler.systemMemory()
            DispatchQueue.main.async {
                self.processes = samples
                self.superNode = usage
                self.memory = memory
                if readSaved {
                    self.savedNodes = roots.savedNodes
                    self.savedNodesRead = Date()
                }
                self.sampling = false
            }
        }
    }

    /// The processes started by Wisp: terminals, their shells and programs.
    func wispProcesses() -> Set<pid_t> {
        Set(ProcessSampler.subtree(getpid(), children: ProcessSampler.children(of: processes)))
    }
}

// MARK: - Window

final class ProcessMonitorWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ProcessMonitorWindowController()

    let model = ProcessMonitorModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Process Monitor"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 320)
        window.center()
        window.setFrameAutosaveName("WispProcessMonitorWindow")
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ProcessMonitorView(model: model, window: window))
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
            show(tab: nil)
        }
    }

    func show(tab: ProcessMonitorModel.Tab?) {
        if let tab { model.tab = tab }
        model.start()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// What SuperNode used at the last sample, while the monitor is open.
    var latestSuperNodeUsage: SuperNodeUsage? {
        model.isRunning ? model.superNode : nil
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}

// MARK: - Formatting

enum ProcessFormat {
    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func cpu(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: value < 10 ? "%.1f" : "%.0f", value)
    }

    private static var users: [uid_t: String] = [:]

    static func user(_ uid: uid_t) -> String {
        if let name = users[uid] { return name }
        let name = getpwuid(uid).flatMap { String(cString: $0.pointee.pw_name) } ?? String(uid)
        users[uid] = name
        return name
    }
}

/// Sortable values for the table, with unknown figures sorting last.
extension ProcessSample {
    var cpuValue: Double { cpu ?? -1 }
    var memoryValue: UInt64 { memory ?? 0 }
    var threadsValue: Int { threads ?? 0 }
    var userName: String { ProcessFormat.user(uid) }
    var pidValue: Int { Int(pid) }
}

// MARK: - Views

struct ProcessMonitorView: View {
    @ObservedObject var model: ProcessMonitorModel
    weak var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.tab) {
                    ForEach(ProcessMonitorModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                SystemSummary(memory: model.memory, processes: model.processes)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch model.tab {
            case .processes: ProcessListView(model: model, window: window)
            case .superNode: SuperNodeUsageView(model: model, window: window)
            }
        }
        .frame(minWidth: 560, minHeight: 320)
    }
}

/// Memory and swap for the whole Mac: when swap fills, everything slows down.
private struct SystemSummary: View {
    let memory: SystemMemory
    let processes: [ProcessSample]

    var body: some View {
        let cpu = processes.reduce(0) { $0 + ($1.cpu ?? 0) }
        let swapHeavy = memory.swapTotal > 0 && Double(memory.swapUsed) / Double(memory.swapTotal) > 0.5
        HStack(spacing: 14) {
            label("CPU", ProcessFormat.cpu(cpu) + "%")
            label("Memory", "\(ProcessFormat.bytes(memory.used)) / \(ProcessFormat.bytes(memory.total))")
            label("Swap", "\(ProcessFormat.bytes(memory.swapUsed)) / \(ProcessFormat.bytes(memory.swapTotal))")
                .foregroundStyle(swapHeavy ? Color.orange : Color.primary)
                .help(swapHeavy ? "Swap is filling up: close apps or tabs you don't need, or restart." : "")
            label("Processes", "\(processes.count)")
        }
        .font(.system(size: 11))
    }

    private func label(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

// MARK: Processes

private struct ProcessListView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all = "All Processes"
        case mine = "My Processes"
        case wisp = "Started by Wisp"
        var id: String { rawValue }
    }

    @ObservedObject var model: ProcessMonitorModel
    weak var window: NSWindow?

    @State private var search = ""
    @State private var scope: Scope = .mine
    @State private var selection: Set<pid_t> = []
    @State private var sortOrder = [KeyPathComparator(\ProcessSample.memoryValue, order: .reverse)]

    private var rows: [ProcessSample] {
        var rows = model.processes
        switch scope {
        case .all: break
        case .mine: rows = rows.filter { $0.uid == getuid() }
        case .wisp:
            let wisp = model.wispProcesses()
            rows = rows.filter { wisp.contains($0.pid) }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            rows = rows.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.commandLine.localizedCaseInsensitiveContains(query)
                    || String($0.pid) == query
            }
        }
        return rows.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Search name, command or PID (e.g. node, mcp)", text: $search)
                    .textFieldStyle(.roundedBorder)
                Text(totals(rows))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(8)

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { process in
                    Text(process.name).help(process.commandLine)
                }
                .width(min: 120, ideal: 180)
                TableColumn("PID", value: \.pidValue) { Text(String($0.pid)).monospacedDigit() }
                    .width(min: 44, ideal: 56)
                TableColumn("CPU %", value: \.cpuValue) { Text(ProcessFormat.cpu($0.cpu)).monospacedDigit() }
                    .width(min: 44, ideal: 56)
                TableColumn("Memory", value: \.memoryValue) { Text(ProcessFormat.bytes($0.memory)).monospacedDigit() }
                    .width(min: 60, ideal: 80)
                TableColumn("Threads", value: \.threadsValue) { Text($0.threads.map(String.init) ?? "–").monospacedDigit() }
                    .width(min: 44, ideal: 54)
                TableColumn("Running", value: \.started) { process in
                    Text(Date().timeIntervalSince(process.started).compactDuration).monospacedDigit()
                }
                .width(min: 50, ideal: 64)
                TableColumn("User", value: \.userName)
                    .width(min: 50, ideal: 70)
                TableColumn("Command") { process in
                    Text(process.commandLine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(process.commandLine)
                }
                .width(min: 120, ideal: 360)
            }
            .contextMenu(forSelectionType: pid_t.self) { pids in
                if !pids.isEmpty {
                    Button("Quit") { end(pids, force: false) }
                    Button("Force Quit") { end(pids, force: true) }
                    Divider()
                    Button("Copy Command Line") { copy(pids) { $0.commandLine } }
                    Button("Copy PID") { copy(pids) { String($0.pid) } }
                }
            }

            Divider()
            HStack {
                Text(selection.isEmpty ? "Select processes to quit them." : "\(selection.count) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { end(selection, force: false) }
                    .disabled(selection.isEmpty)
                Button("Force Quit") { end(selection, force: true) }
                    .disabled(selection.isEmpty)
            }
            .controlSize(.small)
            .padding(8)
        }
    }

    private func totals(_ rows: [ProcessSample]) -> String {
        let cpu = rows.reduce(0) { $0 + ($1.cpu ?? 0) }
        let memory = rows.reduce(UInt64(0)) { $0 + ($1.memory ?? 0) }
        return "\(rows.count) shown · \(ProcessFormat.cpu(cpu))% CPU · \(ProcessFormat.bytes(memory))"
    }

    private func copy(_ pids: Set<pid_t>, _ text: (ProcessSample) -> String) {
        let lines = model.processes.filter { pids.contains($0.pid) }.map(text)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// Asks, then sends SIGTERM (Quit) or SIGKILL (Force Quit).
    private func end(_ pids: Set<pid_t>, force: Bool) {
        let targets = model.processes.filter { pids.contains($0.pid) && $0.pid != getpid() }
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        let names = targets.prefix(5).map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
            + (targets.count > 5 ? " and \(targets.count - 5) more" : "")
        alert.messageText = force ? "Force quit \(targets.count == 1 ? names : "\(targets.count) processes")?" : "Quit \(targets.count == 1 ? names : "\(targets.count) processes")?"
        alert.informativeText = (targets.count == 1 ? "" : names + "\n\n")
            + (force ? "They stop at once and lose anything unsaved." : "They're asked to quit and may save their work first.")
        alert.alertStyle = force ? .critical : .warning
        alert.addButton(withTitle: force ? "Force Quit" : "Quit")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let failed = targets.filter { !ProcessSampler.signal($0.pid, force ? SIGKILL : SIGTERM) }
            selection = []
            model.refresh()
            if !failed.isEmpty {
                let error = NSAlert()
                error.messageText = "Couldn't quit \(failed.map(\.name).joined(separator: ", "))"
                error.informativeText = "They belong to another user, such as the system, or have already quit."
                if let window { error.beginSheetModal(for: window) } else { error.runModal() }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}

// MARK: SuperNode

private struct SuperNodeUsageView: View {
    @ObservedObject var model: ProcessMonitorModel
    weak var window: NSWindow?

    @State private var sortOrder = [KeyPathComparator(\SuperNodeUsage.Entry.memory, order: .reverse)]

    var body: some View {
        let usage = model.superNode
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                figure("Memory", ProcessFormat.bytes(usage.memory))
                figure("CPU", ProcessFormat.cpu(usage.cpu) + "%")
                figure("Processes", "\(usage.processes)")
                Spacer()
                Button(role: .destructive) {
                    SuperNodeController.shared.confirmForceClose(usage: usage, in: window)
                } label: {
                    Label("Force Close SuperNode…", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                .disabled(usage.processes == 0 && SuperNodeController.shared.openCanvases.isEmpty)
                .help("Kill every terminal, agent, chat and web page in SuperNode")
            }
            .padding(12)
            Divider()

            if usage.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("SuperNode isn't running anything")
                        .font(.headline)
                    Text("Terminals, agents, chats and web pages in SuperNode show up here, even for projects that aren't open.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(usage.entries.sorted(using: sortOrder), sortOrder: $sortOrder) {
                    TableColumn("Node", value: \.title) { entry in
                        Label(entry.title, systemImage: entry.symbol)
                    }
                    .width(min: 140, ideal: 220)
                    TableColumn("Project") { entry in
                        Text(entry.project ?? "–").foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 140)
                    TableColumn("CPU %", value: \.cpu) { Text(ProcessFormat.cpu($0.cpu)).monospacedDigit() }
                        .width(min: 44, ideal: 60)
                    TableColumn("Memory", value: \.memory) { Text(ProcessFormat.bytes($0.memory)).monospacedDigit() }
                        .width(min: 60, ideal: 90)
                    TableColumn("Processes") { entry in
                        Text("\(entry.processes)")
                            .monospacedDigit()
                            .help(processNames(entry))
                    }
                    .width(min: 50, ideal: 70)
                }
            }
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
        }
    }

    private func processNames(_ entry: SuperNodeUsage.Entry) -> String {
        let pids = Set(entry.pids)
        return model.processes.filter { pids.contains($0.pid) }
            .map { "\($0.name) (\($0.pid)) · \(ProcessFormat.bytes($0.memory))" }
            .joined(separator: "\n")
    }
}
