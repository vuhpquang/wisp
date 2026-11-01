import AppKit
import Combine
import SwiftUI

/// The uncommitted changes of a repository, like the source control panel of
/// an editor: stage, unstage and discard files, commit, push and switch
/// branches. Connected to a terminal, it follows that terminal's folder.
final class SuperNodeDiffView: SuperNodeNodeView {
    let model = SuperNodeGitModel()
    private var cancellables: Set<AnyCancellable> = []

    override init(item: SuperNodeItem) {
        super.init(item: item)
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        let content = SuperNodeDiffBody(
            model: model,
            onOpen: { [weak self] change in self?.open(change) },
            onDiscard: { [weak self] changes in self?.confirmDiscard(changes) },
            onNewBranch: { [weak self] in self?.promptNewBranch() })
        body = NSHostingView(rootView: content)

        header.addButton(symbol: "folder", tooltip: "Choose a folder", target: self, action: #selector(chooseFolder))
        header.addButton(symbol: "arrow.clockwise", tooltip: "Refresh", target: self, action: #selector(refreshNow))

        model.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshHeader() }
            .store(in: &cancellables)
        refreshHeader()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The repository shown: the folder of a connected terminal, or the folder
    /// the user chose.
    var directory: String? {
        canvas?.sourceDirectory(for: self) ?? item.directory
    }

    override func refreshHeader() {
        super.refreshHeader()
        let status = model.status
        var parts: [String] = []
        if let directory = model.directory { parts.append((directory as NSString).abbreviatingWithTildeInPath) }
        if let branch = status.branch { parts.append(branch) }
        if status.error == nil, model.directory != nil {
            let count = Set((status.staged + status.unstaged).map(\.path)).count
            parts.append(count == 1 ? "1 file" : "\(count) files")
        }
        header.subtitleLabel.stringValue = parts.joined(separator: " · ")
        if status.error == nil, !status.isClean {
            header.badge.show("+\(status.added) −\(status.removed)", color: .systemGreen)
        } else {
            header.badge.show(nil, color: .clear)
        }
    }

    @objc func refreshNow() {
        reload()
    }

    /// Follows the current folder and reloads the changes in the background.
    func reload() {
        model.setDirectory(directory)
        model.refresh()
        refreshHeader()
    }

    override func tearDown() {
        cancellables.removeAll()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Show Changes"
        if let directory { panel.directoryURL = URL(fileURLWithPath: directory) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        item.directory = url.path
        canvas?.disconnectSources(of: self)
        canvas?.documentDidChange()
        reload()
    }

    private func open(_ change: SuperNodeGit.Change) {
        guard let directory = model.directory, change.code != "D" else { return }
        let path = URL(fileURLWithPath: directory).appendingPathComponent(change.path).path
        model.patchText(for: change) { [weak self] patch in
            guard let self else { return }
            self.canvas?.openEditor(path: path, line: SuperNodeGit.firstChangedLine(in: patch), from: self)
        }
    }

    private func confirmDiscard(_ changes: [SuperNodeGit.Change]) {
        guard !changes.isEmpty, let window else { return }
        let alert = NSAlert()
        if changes.count == 1, let change = changes.first {
            alert.messageText = "Discard changes to \(change.name)?"
            alert.informativeText = change.isUntracked
                ? "The file will be moved to the Trash."
                : "Your changes to this file will be lost."
        } else {
            alert.messageText = "Discard changes to \(changes.count) files?"
            alert.informativeText = "Changes to tracked files will be lost. New files will be moved to the Trash."
        }
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.model.discard(changes)
        }
    }

    private func promptNewBranch() {
        canvas?.prompt(title: "New Branch", message: "Create a branch from the current one and switch to it.", value: "") { [weak self] name in
            guard !name.isEmpty else { return }
            self?.model.createBranch(name)
        }
    }
}

// MARK: - SwiftUI

private struct SuperNodeDiffBody: View {
    @ObservedObject var model: SuperNodeGitModel
    let onOpen: (SuperNodeGit.Change) -> Void
    let onDiscard: ([SuperNodeGit.Change]) -> Void
    let onNewBranch: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.directory == nil {
                placeholder("Connect a terminal to this node, or choose a folder.")
            } else if let error = model.status.error {
                placeholder(error)
            } else {
                commitBar
                Divider()
                if model.status.isClean {
                    placeholder("No changes. The working tree is clean.")
                } else {
                    VSplitView {
                    fileList
                        .frame(minHeight: 60, idealHeight: 150, maxHeight: .infinity)
                    SuperNodePatchView(text: model.patch, id: model.patchID)
                        .frame(minHeight: 60, maxHeight: .infinity)
                    }
                }
            }
            if let message = model.message {
                messageBar(message)
            }
        }
        .font(.system(size: 12))
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Commit bar

    private var commitBar: some View {
        let status = model.status
        let commitsAll = status.staged.isEmpty
        return HStack(spacing: 6) {
            branchMenu

            if status.ahead > 0 || status.behind > 0 {
                Text([status.ahead > 0 ? "↑\(status.ahead)" : nil, status.behind > 0 ? "↓\(status.behind)" : nil]
                    .compactMap { $0 }.joined(separator: " "))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            TextField("Commit message", text: $model.commitMessage)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit { model.commit(stagingAll: commitsAll) }

            Button(commitsAll ? "Commit All" : "Commit") {
                model.commit(stagingAll: commitsAll)
            }
            .controlSize(.small)
            .disabled(status.isClean || model.isBusy)
            .help(commitsAll ? "Stage every change and commit" : "Commit the staged changes")

            Menu {
                Button("Push") { model.push() }
                Button("Pull") { model.pull() }
                Divider()
                Button("Stage All Changes") { model.stage(status.unstaged) }
                    .disabled(status.unstaged.isEmpty)
                Button("Unstage All Changes") { model.unstage(status.staged) }
                    .disabled(status.staged.isEmpty)
                Button("Discard All Changes…") { onDiscard(status.unstaged) }
                    .disabled(status.unstaged.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if model.isBusy {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var branchMenu: some View {
        Menu {
            ForEach(model.branches, id: \.self) { branch in
                Button {
                    model.checkout(branch)
                } label: {
                    if branch == model.status.branch {
                        Label(branch, systemImage: "checkmark")
                    } else {
                        Text(branch)
                    }
                }
            }
            Divider()
            Button("New Branch…", action: onNewBranch)
        } label: {
            Label(model.status.branch ?? "No branch", systemImage: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch branch")
    }

    // MARK: Files

    private var fileList: some View {
        let status = model.status
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SuperNodeAllChangesRow(isSelected: model.selection == nil) { model.select(nil) }

                if !status.staged.isEmpty {
                    sectionHeader("Staged Changes", count: status.staged.count) {
                        iconButton("minus", "Unstage all") { model.unstage(status.staged) }
                    }
                    ForEach(status.staged) { row($0) }
                }
                if !status.unstaged.isEmpty {
                    sectionHeader("Changes", count: status.unstaged.count) {
                        iconButton("arrow.uturn.backward", "Discard all changes") { onDiscard(status.unstaged) }
                        iconButton("plus", "Stage all") { model.stage(status.unstaged) }
                    }
                    ForEach(status.unstaged) { row($0) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func sectionHeader<Buttons: View>(_ title: String, count: Int, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 5)
                .background(Color.secondary.opacity(0.2), in: Capsule())
            Spacer()
            buttons()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func row(_ change: SuperNodeGit.Change) -> some View {
        SuperNodeChangeRow(
            change: change,
            isSelected: model.selection == change,
            onSelect: { model.select(change) },
            onOpen: { onOpen(change) },
            onDiscard: { onDiscard([change]) },
            onToggleStage: {
                if change.staged { model.unstage([change]) } else { model.stage([change]) }
            })
    }

    private func messageBar(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
            Text(message)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.message = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11))
        .padding(8)
        .background(Color.orange.opacity(0.15))
    }
}

private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .frame(width: 20, height: 18)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
}

private struct SuperNodeAllChangesRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text("All Changes")
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

private struct SuperNodeChangeRow: View {
    let change: SuperNodeGit.Change
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDiscard: () -> Void
    let onToggleStage: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(change.isUntracked ? "U" : String(change.code))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(change.color))
                .frame(width: 14)
            Text(change.name)
                .lineLimit(1)
                .strikethrough(change.code == "D")
            Text(change.folder)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if isHovered || isSelected {
                if change.code != "D" {
                    iconButton("doc.text", "Open in an editor node", action: onOpen)
                }
                if !change.staged {
                    iconButton("arrow.uturn.backward", "Discard changes", action: onDiscard)
                }
                iconButton(change.staged ? "minus" : "plus", change.staged ? "Unstage" : "Stage", action: onToggleStage)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(isSelected ? Color.accentColor.opacity(0.25) : isHovered ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .help(change.path)
    }
}

/// A read-only, non-wrapping text view for a patch.
private struct SuperNodePatchView: NSViewRepresentable {
    let text: NSAttributedString
    let id: UUID

    final class Coordinator {
        var id: UUID?
        var text: NSAttributedString?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.backgroundColor = .textBackgroundColor
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        guard coordinator.text !== text || coordinator.id != id else { return }

        let samePatch = coordinator.id == id
        let visible = textView.visibleRect
        coordinator.text = text
        coordinator.id = id
        textView.textStorage?.setAttributedString(text)
        // Keep the scroll position when the same patch refreshes; start at the
        // top when it's a different file.
        if samePatch {
            textView.scrollToVisible(visible)
        } else {
            textView.scroll(.zero)
        }
    }
}
